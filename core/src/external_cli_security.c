#define WIN32_LEAN_AND_MEAN
#include <aclapi.h>
#include <lm.h>
#include <sddl.h>
#include <softpub.h>
#include <string.h>
#include <wchar.h>
#include <windows.h>
#include <wintrust.h>

typedef struct {
  void *context;
  const WCHAR *machine;
  int (*alias)(void *, const WCHAR *, PSID, WCHAR *, SID_NAME_USE *);
  BOOL (*members)(void *, LOCALGROUP_MEMBERS_INFO_0 **, DWORD *);
  BOOL (*identity)(void *, const WCHAR *, PSID, WCHAR *, SID_NAME_USE *);
  void (*release)(LOCALGROUP_MEMBERS_INFO_0 *);
} CodexSandboxResolver;

typedef struct {
  DWORD group[SECURITY_MAX_SID_SIZE / sizeof(DWORD)];
  WCHAR machine[MAX_COMPUTERNAME_LENGTH + 1];
  LOCALGROUP_MEMBERS_INFO_0 *members;
  DWORD count;
  BOOL present;
  const CodexSandboxResolver *resolver;
} CodexSandbox;

static int sandbox_alias_system(void *context, const WCHAR *machine, PSID sid,
                                WCHAR *domain, SID_NAME_USE *type) {
  (void)context;
  WCHAR qualified[MAX_COMPUTERNAME_LENGTH + 32];
  DWORD sid_size = SECURITY_MAX_SID_SIZE, domain_size = 256;
  if (swprintf_s(qualified, ARRAYSIZE(qualified), L"%ls\\CodexSandboxUsers",
                 machine) < 0)
    return -1;
  if (!LookupAccountNameW(machine, qualified, sid, &sid_size, domain,
                          &domain_size, type))
    return GetLastError() == ERROR_NONE_MAPPED ? 0 : -1;
  return 1;
}

static BOOL sandbox_members_system(void *context,
                                   LOCALGROUP_MEMBERS_INFO_0 **members,
                                   DWORD *count) {
  (void)context;
  DWORD total = 0;
  NET_API_STATUS status =
      NetLocalGroupGetMembers(NULL, L"CodexSandboxUsers", 0, (LPBYTE *)members,
                              MAX_PREFERRED_LENGTH, count, &total, NULL);
  return status == NERR_Success && *count == total;
}

static BOOL sandbox_identity_system(void *context, const WCHAR *machine,
                                    PSID sid, WCHAR *domain,
                                    SID_NAME_USE *type) {
  (void)context;
  WCHAR name[256];
  DWORD name_size = ARRAYSIZE(name), domain_size = 256;
  return LookupAccountSidW(machine, sid, name, &name_size, domain, &domain_size,
                           type);
}

static void sandbox_members_release(LOCALGROUP_MEMBERS_INFO_0 *members) {
  NetApiBufferFree(members);
}

static const CodexSandboxResolver sandbox_system = {NULL,
                                                    NULL,
                                                    sandbox_alias_system,
                                                    sandbox_members_system,
                                                    sandbox_identity_system,
                                                    sandbox_members_release};

static void codex_sandbox_free(CodexSandbox *sandbox) {
  if (sandbox->members && sandbox->resolver->release)
    sandbox->resolver->release(sandbox->members);
}

/* Only the local SAM alias created by the official Codex sandbox is eligible.
 * Resolve names to binary SIDs; no SID prefix/name-string allowlist. Missing
 * alias adds no trust; failed lookup/enumeration must never add trust either.
 */
static BOOL codex_sandbox_load(CodexSandbox *sandbox,
                               const CodexSandboxResolver *resolver) {
  WCHAR domain[256];
  DWORD machine_size = ARRAYSIZE(sandbox->machine);
  SID_NAME_USE type;
  sandbox->resolver = resolver ? resolver : &sandbox_system;
  if (sandbox->resolver->machine) {
    if (wcscpy_s(sandbox->machine, ARRAYSIZE(sandbox->machine),
                 sandbox->resolver->machine) != 0)
      return FALSE;
  } else if (!GetComputerNameW(sandbox->machine, &machine_size))
    return FALSE;
  int resolved =
      sandbox->resolver->alias(sandbox->resolver->context, sandbox->machine,
                               sandbox->group, domain, &type);
  if (resolved != 1)
    return resolved == 0;
  if (type != SidTypeAlias || !IsValidSid(sandbox->group) ||
      _wcsicmp(domain, sandbox->machine) != 0)
    return FALSE;
  if (!sandbox->resolver->members(sandbox->resolver->context, &sandbox->members,
                                  &sandbox->count))
    return FALSE;
  for (DWORD i = 0; i < sandbox->count; ++i)
    if (!IsValidSid(sandbox->members[i].lgrmi0_sid))
      return FALSE;
  sandbox->present = TRUE;
  return TRUE;
}

/* Do not extend trust to domain accounts, nested groups, or arbitrary local
 * SIDs. Only direct local user members of the resolved alias are accepted.
 * -1 means a member's identity could not be verified. */
static int codex_sandbox_principal(PSID sid, const CodexSandbox *sandbox) {
  if (!sandbox->present)
    return 0;
  if (EqualSid(sid, (PSID)sandbox->group))
    return 1;
  for (DWORD i = 0; i < sandbox->count; ++i) {
    if (!EqualSid(sid, sandbox->members[i].lgrmi0_sid))
      continue;
    BOOL same_domain = FALSE;
    WCHAR domain[256];
    SID_NAME_USE type;
    if (!EqualDomainSid(sid, (PSID)sandbox->group, &same_domain) ||
        !sandbox->resolver->identity(sandbox->resolver->context,
                                     sandbox->machine, sid, domain, &type))
      return -1;
    return same_domain && type == SidTypeUser &&
           _wcsicmp(domain, sandbox->machine) == 0;
  }
  return 0;
}

#ifdef DA_TEST_SEAMS
/* Test seam: the identities come from the same local resolver as production.
 * Text is emitted only to build synthetic descriptors, never used for trust. */
int da_codex_sandbox_sids(char *output, DWORD capacity) {
  CodexSandbox sandbox = {0};
  int result = -1;
  DWORD used = 0;
  if (!output || !capacity)
    return -1;
  output[0] = '\0';
  if (!codex_sandbox_load(&sandbox, NULL))
    goto done;
  if (!sandbox.present) {
    result = 0;
    goto done;
  }
  for (DWORD i = 0; i <= sandbox.count; ++i) {
    PSID sid = i ? sandbox.members[i - 1].lgrmi0_sid : (PSID)sandbox.group;
    if (codex_sandbox_principal(sid, &sandbox) != 1)
      continue;
    LPSTR text = NULL;
    if (!ConvertSidToStringSidA(sid, &text))
      goto done;
    size_t length = strlen(text);
    if (length + 2 > capacity - used) {
      LocalFree(text);
      goto done;
    }
    memcpy(output + used, text, length);
    used += (DWORD)length;
    output[used++] = '\n';
    output[used] = '\0';
    LocalFree(text);
  }
  result = 1;
done:
  codex_sandbox_free(&sandbox);
  if (result != 1)
    output[0] = '\0';
  return result;
}

#endif /* DA_TEST_SEAMS */

/* Binary SID classification: authority 15, package (2) or capability (3).
 * Other authorities/subauthorities remain ordinary principals. */
static BOOL appcontainer_sid(PSID sid) {
  SID_IDENTIFIER_AUTHORITY authority = SECURITY_APP_PACKAGE_AUTHORITY;
  return IsValidSid(sid) &&
         memcmp(GetSidIdentifierAuthority(sid), &authority,
                sizeof(authority)) == 0 &&
         *GetSidSubAuthorityCount(sid) >= 2 &&
         (*GetSidSubAuthority(sid, 0) == SECURITY_APP_PACKAGE_BASE_RID ||
          *GetSidSubAuthority(sid, 0) == SECURITY_CAPABILITY_BASE_RID);
}

/* (13-nov, owner decision «según el SID»). A package SID
 * (S-1-15-2-r1..r7) or the capability SID derived from it (S-1-15-3-r1..r7)
 * names ONE app package: eight subauthorities. Everything else under
 * authority 15 is shared by many confined processes: ALL APPLICATION PACKAGES
 * (S-1-15-2-1), ALL RESTRICTED APPLICATION PACKAGES (S-1-15-2-2), well-known
 * capabilities (S-1-15-3-1 internetClient…) and named capabilities
 * (S-1-15-3-1024-…, nine subauthorities). */
static BOOL package_specific_sid(PSID sid) {
  return appcontainer_sid(sid) && *GetSidSubAuthorityCount(sid) == 8;
}

/* Text of the package SID that a package-specific SID belongs to: the
 * capability form S-1-15-3-X maps to S-1-15-2-X (same seven RIDs). */
static BOOL package_sid_text(PSID sid, WCHAR *out, size_t capacity) {
  if (!package_specific_sid(sid))
    return FALSE;
  int written = swprintf_s(out, capacity, L"S-1-15-2");
  if (written < 0)
    return FALSE;
  for (DWORD i = 1; i < 8; ++i) {
    int more = swprintf_s(out + written, capacity - (size_t)written, L"-%lu",
                          (unsigned long)*GetSidSubAuthority(sid, i));
    if (more < 0)
      return FALSE;
    written += more;
  }
  return TRUE;
}

/* Reads `value` (REG_SZ) of the user's AppContainer mapping for the package
 * of `sid`. 1 = read, 0 = no mapping (package not installed for this user),
 * -1 = error. */
static int package_mapping_value(PSID sid, const WCHAR *value, WCHAR *out,
                                 DWORD out_chars) {
  WCHAR package[96];
  WCHAR key[256];
  if (!package_sid_text(sid, package, ARRAYSIZE(package)))
    return 0;
  if (swprintf_s(key, ARRAYSIZE(key),
                 L"Software\\Classes\\Local Settings\\Software\\Microsoft\\"
                 L"Windows\\CurrentVersion\\AppContainer\\Mappings\\%ls",
                 package) < 0)
    return -1;
  DWORD bytes = out_chars * sizeof(WCHAR);
  LSTATUS status = RegGetValueW(HKEY_CURRENT_USER, key, value, RRF_RT_REG_SZ,
                                NULL, out, &bytes);
  if (status == ERROR_FILE_NOT_FOUND || status == ERROR_PATH_NOT_FOUND)
    return 0;
  return status == ERROR_SUCCESS ? 1 : -1;
}

/* DevAgents' own AppContainer profiles (SEC5 bench, F1.8) use monikers that
 * start with «DevAgents»: a writer from our own sandbox is never accepted,
 * because the point of that sandbox is that it cannot change what DevAgents
 * later runs with full rights. */
int da_appcontainer_moniker_is_devagents(const WCHAR *moniker) {
  return moniker && _wcsnicmp(moniker, L"devagents", 9) == 0;
}

/* may an AppContainer/capability SID with write rights stay as a
 * signal? Only when it names a single package that is not DevAgents' own.
 * The mapping must exist and identify a nonempty, non-DevAgents moniker.
 * Unknown/orphan SIDs fail closed. -1 = registry error. */
static int appcontainer_writer_accepted(PSID sid) {
  if (!package_specific_sid(sid))
    return 0;
  WCHAR moniker[256];
  int found =
      package_mapping_value(sid, L"Moniker", moniker, ARRAYSIZE(moniker));
  if (found < 0)
    return -1;
  if (found != 1 || !moniker[0] ||
      da_appcontainer_moniker_is_devagents(moniker))
    return 0;
  return 1;
}

/* Name of the app that owns a package-specific SID, in UTF-8, for the doctor
 * and Settings: the mapping's DisplayName, or its Moniker when the name is an
 * indirect resource string («@{…}»). 1 = written, 0 = unknown (orphan or
 * shared SID), -1 = error or buffer too small. */
int da_appcontainer_app_name(const char *sid_text, char *out, DWORD capacity) {
  if (!sid_text || !out || !capacity)
    return -1;
  out[0] = '\0';
  PSID sid = NULL;
  if (!ConvertStringSidToSidA(sid_text, &sid))
    return -1;
  WCHAR name[256];
  int found = package_mapping_value(sid, L"DisplayName", name, ARRAYSIZE(name));
  if (found == 1 && name[0] == L'@')
    found = 0;
  if (found == 0)
    found = package_mapping_value(sid, L"Moniker", name, ARRAYSIZE(name));
  LocalFree(sid);
  if (found != 1)
    return found;
  int bytes =
      WideCharToMultiByte(CP_UTF8, 0, name, -1, out, (int)capacity, NULL, NULL);
  if (bytes <= 0) {
    out[0] = '\0';
    return -1;
  }
  return 1;
}

static BOOL trusted_principal(PSID sid, PSID user, PSID installer) {
  return sid && IsValidSid(sid) &&
         (EqualSid(sid, user) || IsWellKnownSid(sid, WinLocalSystemSid) ||
          IsWellKnownSid(sid, WinBuiltinAdministratorsSid) ||
          EqualSid(sid, installer));
}

/* Evaluate each mutation bit in DACL order, including inherited DENY. The
 * first matching ALLOW/DENY decides that bit; a later DENY cannot revoke an
 * earlier grant. No account lookup is needed for synthetic sandbox SIDs.
 * Object/callback DENY cannot be evaluated without object/condition context;
 * a relevant unresolved DENY makes that principal unverifiable.
 * Only a DENY for the same SID cancels its grants: other principals' grants
 * are inspected independently, without assuming any group membership. */
static int acl_effective_writer(PACL acl, PSID sid) {
  DWORD remaining = FILE_WRITE_DATA | FILE_APPEND_DATA | FILE_WRITE_EA |
                    FILE_WRITE_ATTRIBUTES | FILE_DELETE_CHILD | DELETE |
                    WRITE_DAC | WRITE_OWNER;
  GENERIC_MAPPING mapping = {FILE_GENERIC_READ, FILE_GENERIC_WRITE,
                             FILE_GENERIC_EXECUTE, FILE_ALL_ACCESS};
  for (DWORD i = 0; i < acl->AceCount; ++i) {
    ACCESS_ALLOWED_ACE *ace = NULL;
    if (!GetAce(acl, i, (void **)&ace))
      return -1;
    if (ace->Header.AceFlags & INHERIT_ONLY_ACE)
      continue;
    BYTE type = ace->Header.AceType;
    BOOL unresolved_deny = type == ACCESS_DENIED_OBJECT_ACE_TYPE ||
                           type == ACCESS_DENIED_CALLBACK_ACE_TYPE ||
                           type == ACCESS_DENIED_CALLBACK_OBJECT_ACE_TYPE;
    if (type != ACCESS_ALLOWED_ACE_TYPE && type != ACCESS_DENIED_ACE_TYPE &&
        !unresolved_deny)
      continue;
    DWORD offset = FIELD_OFFSET(ACCESS_ALLOWED_ACE, SidStart);
    if (type == ACCESS_DENIED_OBJECT_ACE_TYPE ||
        type == ACCESS_DENIED_CALLBACK_OBJECT_ACE_TYPE) {
      if (ace->Header.AceSize < 3 * sizeof(DWORD))
        return -1;
      ACCESS_DENIED_OBJECT_ACE *object = (ACCESS_DENIED_OBJECT_ACE *)ace;
      if (object->Flags &
          ~(ACE_OBJECT_TYPE_PRESENT | ACE_INHERITED_OBJECT_TYPE_PRESENT))
        return -1;
      offset = 3 * sizeof(DWORD);
      if (object->Flags & ACE_OBJECT_TYPE_PRESENT)
        offset += sizeof(GUID);
      if (object->Flags & ACE_INHERITED_OBJECT_TYPE_PRESENT)
        offset += sizeof(GUID);
    }
    if (ace->Header.AceSize < offset + 8)
      return -1;
    PSID principal = (BYTE *)ace + offset;
    if (GetSidLengthRequired(*GetSidSubAuthorityCount(principal)) >
            ace->Header.AceSize - offset ||
        !IsValidSid(principal))
      return -1;
    if (!EqualSid(sid, principal))
      continue;
    DWORD mask = ace->Mask;
    MapGenericMask(&mask, &mapping);
    if (unresolved_deny && (mask & remaining))
      return -1;
    if (type == ACCESS_DENIED_ACE_TYPE)
      remaining &= ~mask;
    else if (mask & remaining)
      return 1;
  }
  return 0;
}

/* 10-nov (USUARIO-NUEVO): the principal that made an ACL unsafe, as
 * "S-1-...|DOMAIN\name" (name empty when the SID maps to no account), so the
 * rejection can be shown instead of discarding the installation silently. */
static void describe_principal(PSID sid, char *out, DWORD capacity) {
  LPSTR text = NULL;
  WCHAR name[256], domain[256];
  DWORD name_size = ARRAYSIZE(name), domain_size = ARRAYSIZE(domain);
  SID_NAME_USE type;
  char account[600];
  int written = 0;
  if (!out || !capacity)
    return;
  out[0] = '\0';
  if (!ConvertSidToStringSidA(sid, &text))
    return;
  account[0] = '\0';
  if (LookupAccountSidW(NULL, sid, name, &name_size, domain, &domain_size,
                        &type)) {
    WCHAR qualified[520];
    if (swprintf_s(qualified, ARRAYSIZE(qualified), L"%ls\\%ls", domain, name) >
        0)
      written = WideCharToMultiByte(CP_UTF8, 0, qualified, -1, account,
                                    sizeof(account), NULL, NULL);
    if (written <= 0)
      account[0] = '\0';
  }
  size_t sid_len = strlen(text), account_len = strlen(account);
  if (sid_len + account_len + 2 <= capacity) {
    memcpy(out, text, sid_len);
    out[sid_len] = '|';
    memcpy(out + sid_len + 1, account, account_len);
    out[sid_len + 1 + account_len] = '\0';
  }
  LocalFree(text);
}

/* B1 (10-nov, regla delegada por el propietario: «que funcione como la
 * competencia»): un escritor ajeno solo bloquea un EJECUTABLE si de verdad
 * puede usarse para colocar código. Una SID huérfana —una cuenta de dominio
 * de cuentas (S-1-5-21-…) que no resuelve a ninguna cuenta: nadie puede
 * iniciar sesión con ella— no bloquea; se acepta y se informa. Todo lo demás
 * sigue bloqueando: Todos, Usuarios autentificados, BUILTIN\Usuarios,
 * Invitados, Anónimo e INTERACTIVO (resuelven y no son S-1-5-21), cualquier
 * cuenta o grupo que resuelva, SIDs de sesión (S-1-5-5-…) y toda SID cuya
 * búsqueda falle por otro motivo que «no existe» (fallo cerrado).
 * En un equipo unido a un dominio, una SID que el controlador no resuelve
 * puede ser una cuenta real con el controlador inaccesible: ahí solo cuenta
 * como huérfana si pertenece al dominio de cuentas local del equipo.
 * 1 huérfana, 0 no huérfana (bloquea). */
static int orphan_principal(PSID sid) {
  SID_IDENTIFIER_AUTHORITY nt = SECURITY_NT_AUTHORITY;
  if (!IsValidSid(sid) ||
      memcmp(GetSidIdentifierAuthority(sid), &nt, sizeof(nt)) != 0 ||
      *GetSidSubAuthorityCount(sid) < 2 ||
      *GetSidSubAuthority(sid, 0) != SECURITY_NT_NON_UNIQUE)
    return 0;
  WCHAR name[256], domain[256];
  DWORD name_size = ARRAYSIZE(name), domain_size = ARRAYSIZE(domain);
  SID_NAME_USE type;
  if (LookupAccountSidW(NULL, sid, name, &name_size, domain, &domain_size,
                        &type))
    return 0;
  if (GetLastError() != ERROR_NONE_MAPPED)
    return 0;
  LPWSTR joined_name = NULL;
  NETSETUP_JOIN_STATUS status = NetSetupUnknownStatus;
  if (NetGetJoinInformation(NULL, &joined_name, &status) != NERR_Success)
    return 0;
  NetApiBufferFree(joined_name);
  if (status != NetSetupDomainName)
    return 1;
  WCHAR machine[MAX_COMPUTERNAME_LENGTH + 1];
  DWORD machine_size = ARRAYSIZE(machine);
  DWORD local[SECURITY_MAX_SID_SIZE / sizeof(DWORD)];
  DWORD local_size = sizeof(local);
  domain_size = ARRAYSIZE(domain);
  BOOL same = FALSE;
  if (!GetComputerNameW(machine, &machine_size) ||
      !LookupAccountNameW(NULL, machine, (PSID)local, &local_size, domain,
                          &domain_size, &type) ||
      !EqualDomainSid(sid, (PSID)local, &same))
    return 0;
  return same ? 1 : 0;
}

static BOOL append_sid_line(PSID sid, char *out, DWORD capacity) {
  if (!out || !capacity)
    return TRUE;
  LPSTR text = NULL;
  if (!ConvertSidToStringSidA(sid, &text))
    return FALSE;
  size_t used = strlen(out), length = strlen(text);
  BOOL ok = used + length + 2 <= capacity;
  if (ok) {
    memcpy(out + used, text, length);
    out[used + length] = '\n';
    out[used + length + 1] = '\0';
  }
  LocalFree(text);
  return ok;
}

/* Shared by retained-handle checks and synthetic descriptor tests. */
static int inspect_acl(PSECURITY_DESCRIPTOR descriptor, char *signals,
                       DWORD capacity, BOOL owner_only, BOOL codex_profile,
                       const CodexSandboxResolver *resolver, char *blocker,
                       DWORD blocker_capacity, BOOL accept_orphans,
                       char *orphans, DWORD orphans_capacity) {
  CodexSandbox sandbox = {0};
  BOOL sandbox_loaded = FALSE;
  HANDLE token = NULL;
  TOKEN_USER *user = NULL;
  PSID owner = NULL;
  PSID installer = NULL;
  PACL acl = NULL;
  DWORD size = 0;
  int result = -1;
  DWORD used = 0;
  if (signals) {
    if (!capacity)
      return -1;
    signals[0] = '\0';
  }
  if (orphans && orphans_capacity)
    orphans[0] = '\0';
  if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token))
    goto done;
  GetTokenInformation(token, TokenUser, NULL, 0, &size);
  if (!size)
    goto done;
  user = (TOKEN_USER *)LocalAlloc(LPTR, size);
  if (!user || !GetTokenInformation(token, TokenUser, user, size, &size))
    goto done;
  if (!ConvertStringSidToSidW(
          L"S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464",
          &installer))
    goto done;
  BOOL present = FALSE, defaulted = FALSE;
  if (!GetSecurityDescriptorOwner(descriptor, &owner, &defaulted))
    goto done;
  /* Owners have implicit WRITE_DAC even without a write ACE. AppContainer
   * grants are exempt below; ownership is never exempt from this allowlist. */
  if (!trusted_principal(owner, user->User.Sid, installer)) {
    result = 2;
    goto done;
  }
  if (owner_only) {
    result = 1;
    goto done;
  }
  if (!GetSecurityDescriptorDacl(descriptor, &present, &acl, &defaulted))
    goto done;
  if (!present || !acl) {
    result = 0;
    goto done;
  }
  for (DWORD i = 0; i < acl->AceCount; ++i) {
    ACCESS_ALLOWED_ACE *ace = NULL;
    if (!GetAce(acl, i, (void **)&ace))
      goto done;
    if (ace->Header.AceFlags & INHERIT_ONLY_ACE)
      continue;
    if (ace->Header.AceType != ACCESS_ALLOWED_ACE_TYPE) {
      /* Object/callback grants need a different SID layout: fail closed. */
      if (ace->Header.AceType == ACCESS_ALLOWED_OBJECT_ACE_TYPE ||
          ace->Header.AceType == ACCESS_ALLOWED_CALLBACK_ACE_TYPE ||
          ace->Header.AceType == ACCESS_ALLOWED_CALLBACK_OBJECT_ACE_TYPE)
        goto done;
      continue;
    }
    const DWORD writes = FILE_WRITE_DATA | FILE_APPEND_DATA | FILE_WRITE_EA |
                         FILE_WRITE_ATTRIBUTES | FILE_DELETE_CHILD | DELETE |
                         WRITE_DAC | WRITE_OWNER | GENERIC_WRITE | GENERIC_ALL;
    PSID sid = &ace->SidStart;
    if (ace->Header.AceSize < sizeof(ACCESS_ALLOWED_ACE) || !IsValidSid(sid) ||
        GetLengthSid(sid) >
            ace->Header.AceSize - FIELD_OFFSET(ACCESS_ALLOWED_ACE, SidStart))
      goto done;
    if (appcontainer_sid(sid)) {
      /* e5-harden punto 3, narrowed by (13-nov, owner decision): a
       * read-only AppContainer/capability SID is a signal. With a write bit
       * it is rejected when many confined processes share it (ALL
       * APPLICATION PACKAGES, well-known or named capabilities) or when it is
       * DevAgents' own sandbox; the SID of ONE known installed
       * app package stays a signal, listed with the «w:» prefix so the
       * doctor and Settings say which app can write and how to remove it.
       * Measured case: the Claude desktop MSIX package holds Full Control on
       * %USERPROFILE%\AppData, which every npm CLI inherits. */
      BOOL writable = (ace->Mask & writes) != 0;
      if (writable) {
        int accepted = appcontainer_writer_accepted(sid);
        if (accepted < 0)
          goto done;
        if (!accepted) {
          describe_principal(sid, blocker, blocker_capacity);
          result = 0;
          goto done;
        }
      }
      if (signals) {
        LPSTR text = NULL;
        if (!ConvertSidToStringSidA(sid, &text))
          goto done;
        size_t length = strlen(text);
        size_t prefix = writable ? 2 : 0;
        if (length + prefix + 2 > capacity - used) {
          LocalFree(text);
          goto done;
        }
        if (writable) {
          memcpy(signals + used, "w:", 2);
          used += 2;
        }
        memcpy(signals + used, text, length);
        used += (DWORD)length;
        signals[used++] = '\n';
        signals[used] = '\0';
        LocalFree(text);
      }
      continue;
    }
    if (!(ace->Mask & writes))
      continue;
    /* B1c (11-nov): OWNER RIGHTS (S-1-3-4) only grants to whoever owns the
     * object, and the owner already passed trusted_principal above, so in the
     * binary gate it is not a foreign writer. The strict gate (working
     * folders) keeps treating it as one: unchanged behaviour there. */
    if (accept_orphans && IsWellKnownSid(sid, WinCreatorOwnerRightsSid))
      continue;
    if (!trusted_principal(sid, user->User.Sid, installer)) {
      /* CODEX_HOME/auth.json and, by owner decision of 10-nov (USUARIO-NUEVO,
       * A2), CLI binaries and their installation directories accept the
       * official local Codex sandbox alias and its direct local user members:
       * the Codex Windows sandbox grants them Modify on the user profile and
       * the native Claude Code install inherited it. Any other foreign writer
       * is still rejected. Keep the owner gate strict; foreign SIDs must have
       * effective writes before they count as untrusted writers. */
      if (codex_profile) {
        if (!sandbox_loaded) {
          if (!codex_sandbox_load(&sandbox, resolver)) {
            result = -3;
            goto done;
          }
          sandbox_loaded = TRUE;
        }
        int accepted = codex_sandbox_principal(sid, &sandbox);
        if (accepted < 0) {
          result = -3;
          goto done;
        }
        if (accepted)
          continue;
        int writer = acl_effective_writer(acl, sid);
        if (writer < 0)
          goto done;
        if (!writer)
          continue;
      }
      if (accept_orphans && orphan_principal(sid) == 1) {
        /* Listed once per SID; a full buffer is an error, not a silent cut. */
        BOOL listed = FALSE;
        if (orphans && orphans_capacity) {
          LPSTR text = NULL;
          if (!ConvertSidToStringSidA(sid, &text))
            goto done;
          size_t length = strlen(text);
          for (const char *at = strstr(orphans, text); at && !listed;
               at = strstr(at + 1, text))
            listed = (at == orphans || at[-1] == '\n') && at[length] == '\n';
          LocalFree(text);
        }
        if (!listed && !append_sid_line(sid, orphans, orphans_capacity))
          goto done;
        continue;
      }
      describe_principal(sid, blocker, blocker_capacity);
      result = 0;
      goto done;
    }
  }
  result = 1;
done:
  codex_sandbox_free(&sandbox);
  if (result != 1 && signals && capacity)
    signals[0] = '\0';
  if (result != 1 && orphans && orphans_capacity)
    orphans[0] = '\0';
  if (installer)
    LocalFree(installer);
  if (user)
    LocalFree(user);
  if (token)
    CloseHandle(token);
  return result;
}

static int inspect_handle(HANDLE file, char *signals, DWORD capacity,
                          BOOL owner_only, BOOL codex_profile, char *blocker,
                          DWORD blocker_capacity, BOOL accept_orphans,
                          char *orphans, DWORD orphans_capacity) {
  PSECURITY_DESCRIPTOR descriptor = NULL;
  /* INVALID_HANDLE_VALUE is also the process pseudo-handle on Windows;
   * GetSecurityInfo alone cannot establish that it is a retained file. */
  if (!file || file == INVALID_HANDLE_VALUE)
    return -1;
  if (GetSecurityInfo(file, SE_FILE_OBJECT,
                      OWNER_SECURITY_INFORMATION |
                          (owner_only ? 0 : DACL_SECURITY_INFORMATION),
                      NULL, NULL, NULL, NULL, &descriptor) != ERROR_SUCCESS)
    return -1;
  int result = inspect_acl(descriptor, signals, capacity, owner_only,
                           codex_profile, NULL, blocker, blocker_capacity,
                           accept_orphans, orphans, orphans_capacity);
  LocalFree(descriptor);
  return result;
}

/* Strict gate (governed workspaces, CODEX_HOME): official Codex sandbox
 * writers accepted (see inspect_acl); -3 = the sandbox identity could not be
 * verified. An orphan SID still blocks here: a working folder is not an
 * installation, and the cost of a false accept is a foreign writer inside the
 * tree the agent governs. */
int da_cli_acl_inspect(HANDLE file, char *signals, DWORD capacity) {
  return inspect_handle(file, signals, capacity, FALSE, TRUE, NULL, 0, FALSE,
                        NULL, 0);
}

int da_codex_profile_acl_safe(HANDLE file) {
  return inspect_handle(file, NULL, 0, FALSE, TRUE, NULL, 0, FALSE, NULL, 0);
}

int da_cli_acl_safe(HANDLE file) { return da_cli_acl_inspect(file, NULL, 0); }

/* B1: binary and installation gate. Same as da_cli_acl_inspect, but an orphan
 * writer (orphan_principal) is accepted and listed in `orphans`, one SID per
 * line. */
int da_cli_binary_acl_inspect(HANDLE file, char *signals, DWORD capacity,
                              char *orphans, DWORD orphans_capacity) {
  return inspect_handle(file, signals, capacity, FALSE, TRUE, NULL, 0, TRUE,
                        orphans, orphans_capacity);
}

/* Same verdict as the binary gate; on 0 also names the foreign writer. */
int da_cli_acl_blocker(HANDLE file, char *blocker, DWORD capacity) {
  if (blocker && capacity)
    blocker[0] = '\0';
  return inspect_handle(file, NULL, 0, FALSE, TRUE, blocker, capacity, TRUE,
                        NULL, 0);
}

/* Ancestors above the installation root have a trusted owner requirement,
 * while their ordinary directory write grants are outside the ACL gate. */
int da_cli_owner_safe(HANDLE file) {
  return inspect_handle(file, NULL, 0, TRUE, FALSE, NULL, 0, FALSE, NULL, 0);
}

#include "private_data_security.h"

DWORD da_cli_create_private_directory(const WCHAR *path) {
  PrivateDirectoryDescriptor value = {0};
  DWORD result = private_directory_descriptor(&value);
  if (result == ERROR_SUCCESS) {
    SECURITY_ATTRIBUTES attributes = {sizeof(attributes), &value.descriptor,
                                      FALSE};
    result =
        CreateDirectoryW(path, &attributes) ? ERROR_SUCCESS : GetLastError();
  }
  private_directory_descriptor_free(&value);
  return result;
}

DWORD da_private_data_directory(const WCHAR *path) {
  return private_data_directory(path);
}

DWORD da_private_data_protect_file(const WCHAR *path) {
  PrivateDirectoryDescriptor value = {0};
  DWORD result = private_directory_descriptor(&value);
  if (result == ERROR_SUCCESS)
    result = private_data_protect(path, &value.descriptor, FALSE);
  private_directory_descriptor_free(&value);
  return result;
}

DWORD da_private_data_write_new(const WCHAR *path, const void *data,
                                DWORD length) {
  PrivateDirectoryDescriptor value = {0};
  DWORD result = private_directory_descriptor(&value);
  if (result == ERROR_SUCCESS) {
    SECURITY_ATTRIBUTES attributes = {sizeof(attributes), &value.descriptor,
                                      FALSE};
    HANDLE file = CreateFileW(path, GENERIC_WRITE, 0, &attributes, CREATE_NEW,
                              FILE_ATTRIBUTE_NORMAL, NULL);
    if (file == INVALID_HANDLE_VALUE)
      result = GetLastError();
    else {
      DWORD written = 0;
      if (!WriteFile(file, data, length, &written, NULL))
        result = GetLastError();
      else if (written != length)
        result = ERROR_WRITE_FAULT;
      CloseHandle(file);
    }
  }
  private_directory_descriptor_free(&value);
  return result;
}

/* Test seam: parses real Win32 descriptors, using the production scanner. */
static int inspect_sddl(const WCHAR *sddl, char *signals, DWORD capacity,
                        BOOL owner_only, BOOL codex_profile,
                        BOOL accept_orphans, char *orphans,
                        DWORD orphans_capacity) {
  PSECURITY_DESCRIPTOR descriptor = NULL;
  if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(
          sddl, SDDL_REVISION_1, &descriptor, NULL))
    return -1;
  int result =
      inspect_acl(descriptor, signals, capacity, owner_only, codex_profile,
                  NULL, NULL, 0, accept_orphans, orphans, orphans_capacity);
  LocalFree(descriptor);
  return result;
}

/* Same policy as the strict retained-handle gate (da_cli_acl_inspect). */
int da_cli_acl_sddl(const WCHAR *sddl, char *signals, DWORD capacity) {
  return inspect_sddl(sddl, signals, capacity, FALSE, TRUE, FALSE, NULL, 0);
}

/* B1: same policy as the binary gate (da_cli_binary_acl_inspect). */
int da_cli_binary_acl_sddl(const WCHAR *sddl, char *orphans,
                           DWORD orphans_capacity) {
  return inspect_sddl(sddl, NULL, 0, FALSE, TRUE, TRUE, orphans,
                      orphans_capacity);
}

#ifdef DA_TEST_SEAMS
int da_codex_profile_acl_sddl(const WCHAR *sddl) {
  return inspect_sddl(sddl, NULL, 0, FALSE, TRUE, FALSE, NULL, 0);
}
#endif /* DA_TEST_SEAMS */

int da_cli_owner_sddl(const WCHAR *sddl) {
  return inspect_sddl(sddl, NULL, 0, TRUE, FALSE, FALSE, NULL, 0);
}

#ifdef DA_TEST_SEAMS
/* Deterministic SAM seam: inject resolution results, not trusted principals.
 * The production alias/type/domain/member checks still decide eligibility.
 * Scenarios: 0 local alias/users; 1 domain group; 2 local user masquerading as
 * alias; 3 domain user; 4 absent; 5 domain member; 6 nested group;
 * 7 alias lookup failure; 8 member lookup failure. */
typedef struct {
  DWORD scenario;
  PSID group;
  LOCALGROUP_MEMBERS_INFO_0 member;
} SandboxFixture;

static int sandbox_alias_fixture(void *context, const WCHAR *machine, PSID sid,
                                 WCHAR *domain, SID_NAME_USE *type) {
  SandboxFixture *fixture = context;
  if (fixture->scenario == 4)
    return 0;
  if (fixture->scenario == 7)
    return -1;
  if (!CopySid(SECURITY_MAX_SID_SIZE, sid, fixture->group) ||
      wcscpy_s(domain, 256,
               fixture->scenario == 1 || fixture->scenario == 3
                   ? L"fixture-domain"
                   : machine) != 0)
    return -1;
  *type = fixture->scenario == 1                             ? SidTypeGroup
          : fixture->scenario == 2 || fixture->scenario == 3 ? SidTypeUser
                                                             : SidTypeAlias;
  return 1;
}

static BOOL sandbox_members_fixture(void *context,
                                    LOCALGROUP_MEMBERS_INFO_0 **members,
                                    DWORD *count) {
  SandboxFixture *fixture = context;
  *members = &fixture->member;
  *count = 1;
  return TRUE;
}

static BOOL sandbox_identity_fixture(void *context, const WCHAR *machine,
                                     PSID sid, WCHAR *domain,
                                     SID_NAME_USE *type) {
  SandboxFixture *fixture = context;
  if (fixture->scenario == 8 || !EqualSid(sid, fixture->member.lgrmi0_sid))
    return FALSE;
  *type = fixture->scenario == 6 ? SidTypeAlias : SidTypeUser;
  return wcscpy_s(domain, 256,
                  fixture->scenario == 5 ? L"fixture-domain" : machine) == 0;
}

int da_codex_profile_acl_fixture(const WCHAR *sddl, DWORD scenario) {
  SandboxFixture fixture = {0};
  PSECURITY_DESCRIPTOR descriptor = NULL;
  int result = -1;
  if (scenario > 8)
    return -1;
  fixture.scenario = scenario;
  if (!ConvertStringSidToSidW(L"S-1-5-21-123-456-789-1001", &fixture.group) ||
      !ConvertStringSidToSidW(L"S-1-5-21-123-456-789-1002",
                              &fixture.member.lgrmi0_sid) ||
      !ConvertStringSecurityDescriptorToSecurityDescriptorW(
          sddl, SDDL_REVISION_1, &descriptor, NULL))
    goto done;
  const CodexSandboxResolver resolver = {&fixture,
                                         L"fixture-local",
                                         sandbox_alias_fixture,
                                         sandbox_members_fixture,
                                         sandbox_identity_fixture,
                                         NULL};
  result = inspect_acl(descriptor, NULL, 0, FALSE, TRUE, &resolver, NULL, 0,
                       FALSE, NULL, 0);
done:
  if (descriptor)
    LocalFree(descriptor);
  if (fixture.group)
    LocalFree(fixture.group);
  if (fixture.member.lgrmi0_sid)
    LocalFree(fixture.member.lgrmi0_sid);
  return result;
}

#endif /* DA_TEST_SEAMS */

/* Additional signal, never a substitute for root/handle/ACL checks. No UI or
 * network retrieval. Only zero means a trusted Authenticode signature. */
LONG da_cli_authenticode(HANDLE file, const WCHAR *path) {
  GUID action = WINTRUST_ACTION_GENERIC_VERIFY_V2;
  WINTRUST_FILE_INFO info = {0};
  WINTRUST_DATA data = {0};
  info.cbStruct = sizeof(info);
  info.pcwszFilePath = path;
  info.hFile = file;
  data.cbStruct = sizeof(data);
  data.dwUIChoice = WTD_UI_NONE;
  data.dwUnionChoice = WTD_CHOICE_FILE;
  data.pFile = &info;
  data.dwStateAction = WTD_STATEACTION_VERIFY;
  data.dwProvFlags = WTD_CACHE_ONLY_URL_RETRIEVAL | WTD_REVOCATION_CHECK_NONE;
  LONG result = WinVerifyTrust((HWND)INVALID_HANDLE_VALUE, &action, &data);
  data.dwStateAction = WTD_STATEACTION_CLOSE;
  WinVerifyTrust((HWND)INVALID_HANDLE_VALUE, &action, &data);
  return result;
}

typedef struct {
  HANDLE directory;
  PSECURITY_DESCRIPTOR descriptor;
  SECURITY_DESCRIPTOR_CONTROL control;
  BOOL rewritten; /* last restore changed the live descriptor */
} WorkspacePermissions;

static DWORD workspace_directory_open(const WCHAR *path, DWORD access,
                                      HANDLE *output) {
  FILE_ATTRIBUTE_TAG_INFO info;
  *output = CreateFileW(
      path, access | FILE_READ_ATTRIBUTES, FILE_SHARE_READ | FILE_SHARE_WRITE,
      NULL, OPEN_EXISTING,
      FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, NULL);
  if (*output == INVALID_HANDLE_VALUE)
    return GetLastError();
  DWORD result = ERROR_SUCCESS;
  if (!GetFileInformationByHandleEx(*output, FileAttributeTagInfo, &info,
                                    sizeof(info)))
    result = GetLastError();
  else if (info.FileAttributes & FILE_ATTRIBUTE_REPARSE_POINT)
    result = ERROR_REPARSE_TAG_INVALID;
  else if (!(info.FileAttributes & FILE_ATTRIBUTE_DIRECTORY))
    result = ERROR_DIRECTORY;
  if (result != ERROR_SUCCESS) {
    CloseHandle(*output);
    *output = INVALID_HANDLE_VALUE;
  }
  return result;
}

void da_workspace_permissions_free(WorkspacePermissions *snapshot) {
  if (!snapshot)
    return;
  if (snapshot->descriptor)
    LocalFree(snapshot->descriptor);
  if (snapshot->directory != INVALID_HANDLE_VALUE)
    CloseHandle(snapshot->directory);
  LocalFree(snapshot);
}

DWORD da_workspace_permissions_capture(const WCHAR *path,
                                       WorkspacePermissions **output) {
  *output = NULL;
  WorkspacePermissions *snapshot = LocalAlloc(LPTR, sizeof(*snapshot));
  if (!snapshot)
    return ERROR_NOT_ENOUGH_MEMORY;
  snapshot->directory = INVALID_HANDLE_VALUE;
  /* READ_CONTROL only: capturing must never demand more rights than a CLI that
   * runs fine in an ordinary user folder. Write rights are requested lazily by
   * workspace_descriptor_restore, and only when the descriptor changed. */
  DWORD result =
      workspace_directory_open(path, READ_CONTROL, &snapshot->directory);
  if (result == ERROR_SUCCESS)
    result =
        GetSecurityInfo(snapshot->directory, SE_FILE_OBJECT,
                        OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION,
                        NULL, NULL, NULL, NULL, &snapshot->descriptor);
  DWORD revision;
  if (result == ERROR_SUCCESS &&
      !GetSecurityDescriptorControl(snapshot->descriptor, &snapshot->control,
                                    &revision))
    result = GetLastError();
  if (result != ERROR_SUCCESS) {
    da_workspace_permissions_free(snapshot);
    SetLastError(result);
    return result;
  }
  *output = snapshot;
  return ERROR_SUCCESS;
}

static DWORD workspace_handle_identity(HANDLE directory, char *output,
                                       DWORD capacity);

/* Write rights on the SAME retained object. ReOpenFile cannot upgrade a
 * READ_CONTROL-only handle (ERROR_ACCESS_DENIED even for the owner), so the
 * object is opened by its 128-bit file id, with the retained handle as volume
 * hint: the path is never resolved again. The identity check proves the new
 * handle is that very directory. */
static DWORD workspace_reopen_for_write(HANDLE directory, DWORD access,
                                        HANDLE *writer) {
  char before[64], after[64];
  FILE_ID_INFO info;
  FILE_ID_DESCRIPTOR id;
  *writer = INVALID_HANDLE_VALUE;
  if (!GetFileInformationByHandleEx(directory, FileIdInfo, &info, sizeof(info)))
    return GetLastError();
  memset(&id, 0, sizeof(id));
  id.dwSize = sizeof(id);
  id.Type = ExtendedFileIdType;
  id.ExtendedFileId = info.FileId;
  *writer =
      OpenFileById(directory, &id, access | FILE_READ_ATTRIBUTES,
                   FILE_SHARE_READ | FILE_SHARE_WRITE, NULL,
                   FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT);
  if (*writer == INVALID_HANDLE_VALUE)
    return GetLastError();
  DWORD result = workspace_handle_identity(directory, before, sizeof(before));
  if (result == ERROR_SUCCESS)
    result = workspace_handle_identity(*writer, after, sizeof(after));
  if (result == ERROR_SUCCESS && strcmp(before, after) != 0)
    result = ERROR_INVALID_HANDLE;
  if (result != ERROR_SUCCESS) {
    CloseHandle(*writer);
    *writer = INVALID_HANDLE_VALUE;
  }
  return result;
}

/* Puts a descriptor back on the retained root handle (opened READ_CONTROL).
 * WRITE_DAC is requested only now, WRITE_OWNER only if the owner changed; if
 * those rights are missing the caller gets that error at restore time.
 *
 * propagate=TRUE first pushes the inheritable entries to the children with the
 * documented file API, then fixes the root with the Nt form (SetSecurityInfo
 * can synthesize inheritance/control bits on the root). No child explicit
 * entries are removed; protected child DACLs remain protected.
 * propagate=FALSE only rewrites the root object: the Nt call never walks the
 * tree, so it cannot reach anything outside the retained directory. */
static DWORD workspace_descriptor_restore(HANDLE directory,
                                          PSECURITY_DESCRIPTOR descriptor,
                                          BOOL propagate) {
  PSID owner;
  PACL acl;
  BOOL present, defaulted;
  SECURITY_DESCRIPTOR_CONTROL control;
  DWORD revision;
  if (!GetSecurityDescriptorOwner(descriptor, &owner, &defaulted) ||
      !GetSecurityDescriptorDacl(descriptor, &present, &acl, &defaulted) ||
      !GetSecurityDescriptorControl(descriptor, &control, &revision))
    return GetLastError();
  PSECURITY_DESCRIPTOR current = NULL;
  PSID current_owner = NULL;
  DWORD result =
      GetSecurityInfo(directory, SE_FILE_OBJECT, OWNER_SECURITY_INFORMATION,
                      &current_owner, NULL, NULL, NULL, &current);
  if (result != ERROR_SUCCESS)
    return result;
  BOOL same_owner = owner && current_owner && EqualSid(owner, current_owner);
  LocalFree(current);
  /* Reassigning an unchanged foreign owner can require SeRestorePrivilege.
   * Preserve it without an unnecessary ownership write; changed ownership must
   * still be restored explicitly or reported as a visible failure. */
  SECURITY_INFORMATION information =
      (same_owner ? 0 : OWNER_SECURITY_INFORMATION) |
      DACL_SECURITY_INFORMATION |
      ((control & SE_DACL_PROTECTED) ? PROTECTED_DACL_SECURITY_INFORMATION
                                     : UNPROTECTED_DACL_SECURITY_INFORMATION);
  HANDLE writer = INVALID_HANDLE_VALUE;
  result = workspace_reopen_for_write(
      directory, READ_CONTROL | WRITE_DAC | (same_owner ? 0 : WRITE_OWNER),
      &writer);
  if (result != ERROR_SUCCESS)
    return result;
  if (propagate) {
    result = SetSecurityInfo(writer, SE_FILE_OBJECT, information, owner, NULL,
                             present ? acl : NULL, NULL);
    if (result != ERROR_SUCCESS) {
      CloseHandle(writer);
      return result;
    }
  }
  /* The native descriptor setter operates on the retained file object. Unlike
   * SetKernelObjectSecurity (documented for kernel objects, not files), this is
   * the user-mode Nt form of the documented ZwSetSecurityObject file operation.
   * It preserves the captured descriptor control rather than synthesizing AI.
   */
  typedef LONG(NTAPI * SetSecurityFn)(HANDLE, SECURITY_INFORMATION,
                                      PSECURITY_DESCRIPTOR);
  typedef ULONG(NTAPI * StatusErrorFn)(LONG);
  HMODULE ntdll = GetModuleHandleW(L"ntdll.dll");
  SetSecurityFn set_security =
      ntdll ? (SetSecurityFn)GetProcAddress(ntdll, "NtSetSecurityObject")
            : NULL;
  StatusErrorFn status_error =
      ntdll ? (StatusErrorFn)GetProcAddress(ntdll, "RtlNtStatusToDosError")
            : NULL;
  if (!set_security || !status_error) {
    CloseHandle(writer);
    return ntdll ? ERROR_PROC_NOT_FOUND : GetLastError();
  }
  /* T2d-D4 (12-nov): the Nt setter keeps SE_DACL_AUTO_INHERITED only when the
   * descriptor also carries SE_DACL_AUTO_INHERIT_REQ; without it an ordinary
   * user folder (inherited DACL, "D:AI") came back as "D:" and the compare
   * after restore failed with ERROR_INVALID_SECURITY_DESCR after every Codex
   * run. A protected folder ("D:PAI", inheritance turned off in Explorer)
   * lost its AI the same way. With the request bit the system recomputes the
   * inherited entries from the parent (none when protected), as for a newly
   * created child. The captured descriptor is not modified: a self-relative
   * copy carries the bit. */
  PSECURITY_DESCRIPTOR native = descriptor;
  PSECURITY_DESCRIPTOR copy = NULL;
  if ((control & SE_DACL_AUTO_INHERITED) && (control & SE_SELF_RELATIVE)) {
    DWORD length = GetSecurityDescriptorLength(descriptor);
    copy = LocalAlloc(LPTR, length);
    if (!copy) {
      CloseHandle(writer);
      return ERROR_NOT_ENOUGH_MEMORY;
    }
    memcpy(copy, descriptor, length);
    if (!SetSecurityDescriptorControl(copy, SE_DACL_AUTO_INHERIT_REQ,
                                      SE_DACL_AUTO_INHERIT_REQ)) {
      DWORD error = GetLastError();
      LocalFree(copy);
      CloseHandle(writer);
      return error;
    }
    native = copy;
  }
  LONG status = set_security(writer, information, native);
  CloseHandle(writer);
  if (copy)
    LocalFree(copy);
  if (status < 0)
    return status_error(status);
  return ERROR_SUCCESS;
}

static DWORD workspace_descriptor_sddl(PSECURITY_DESCRIPTOR descriptor,
                                       LPSTR *output) {
  if (!ConvertSecurityDescriptorToStringSecurityDescriptorA(
          descriptor, SDDL_REVISION_1,
          OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION, output, NULL))
    return GetLastError();
  return ERROR_SUCCESS;
}

/* Live owner/DACL of the retained directory: control bits plus SDDL. */
static DWORD workspace_live_descriptor(HANDLE directory,
                                       SECURITY_DESCRIPTOR_CONTROL *control,
                                       LPSTR *sddl) {
  PSECURITY_DESCRIPTOR live = NULL;
  DWORD revision;
  *sddl = NULL;
  DWORD result =
      GetSecurityInfo(directory, SE_FILE_OBJECT,
                      OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION,
                      NULL, NULL, NULL, NULL, &live);
  if (result == ERROR_SUCCESS &&
      !GetSecurityDescriptorControl(live, control, &revision))
    result = GetLastError();
  if (result == ERROR_SUCCESS)
    result = workspace_descriptor_sddl(live, sddl);
  if (live)
    LocalFree(live);
  return result;
}

/* Owner, DACL and control bits of the live root against the captured ones. */
static DWORD workspace_compare(const WorkspacePermissions *snapshot,
                               BOOL *same) {
  SECURITY_DESCRIPTOR_CONTROL control = 0;
  LPSTR live = NULL, captured = NULL;
  *same = FALSE;
  DWORD result =
      workspace_live_descriptor(snapshot->directory, &control, &live);
  if (result == ERROR_SUCCESS)
    result = workspace_descriptor_sddl(snapshot->descriptor, &captured);
  if (result == ERROR_SUCCESS)
    *same = control == snapshot->control && strcmp(live, captured) == 0;
  if (live)
    LocalFree(live);
  if (captured)
    LocalFree(captured);
  return result;
}

/* Propagating inheritance walks every child by path. A reparse point (junction
 * or symlink) or a file with several hard links can expose an object outside
 * the workspace: a hard link shares one security descriptor with its external
 * twin. Scan the tree WITHOUT following reparse points; any such entry makes
 * the caller restore the root only and report DA_WORKSPACE_TREE_HAS_LINKS.
 * Unreadable entries and excessive depth also fail closed. */
#define DA_WORKSPACE_TREE_HAS_LINKS 0xE0DA0001u
#define DA_WORKSPACE_SCAN_DEPTH 256

static DWORD workspace_scan_directory(const WCHAR *directory, DWORD depth) {
  if (depth > DA_WORKSPACE_SCAN_DEPTH)
    return DA_WORKSPACE_TREE_HAS_LINKS;
  size_t length = wcslen(directory);
  WCHAR *pattern = LocalAlloc(LPTR, (length + 3) * sizeof(WCHAR));
  if (!pattern)
    return ERROR_NOT_ENOUGH_MEMORY;
  wcscpy_s(pattern, length + 3, directory);
  wcscat_s(pattern, length + 3, L"\\*");
  WIN32_FIND_DATAW entry;
  HANDLE find = FindFirstFileExW(pattern, FindExInfoBasic, &entry,
                                 FindExSearchNameMatch, NULL, 0);
  LocalFree(pattern);
  if (find == INVALID_HANDLE_VALUE) {
    DWORD error = GetLastError();
    return error == ERROR_FILE_NOT_FOUND ? ERROR_SUCCESS : error;
  }
  DWORD result = ERROR_SUCCESS;
  for (;;) {
    if (wcscmp(entry.cFileName, L".") != 0 &&
        wcscmp(entry.cFileName, L"..") != 0) {
      if (entry.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) {
        result = DA_WORKSPACE_TREE_HAS_LINKS;
        break;
      }
      size_t capacity = length + 1 + wcslen(entry.cFileName) + 1;
      WCHAR *child = LocalAlloc(LPTR, capacity * sizeof(WCHAR));
      if (!child) {
        result = ERROR_NOT_ENOUGH_MEMORY;
        break;
      }
      wcscpy_s(child, capacity, directory);
      wcscat_s(child, capacity, L"\\");
      wcscat_s(child, capacity, entry.cFileName);
      if (entry.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) {
        result = workspace_scan_directory(child, depth + 1);
      } else {
        HANDLE file = CreateFileW(
            child, FILE_READ_ATTRIBUTES,
            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL,
            OPEN_EXISTING,
            FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, NULL);
        BY_HANDLE_FILE_INFORMATION info;
        if (file == INVALID_HANDLE_VALUE)
          result = GetLastError();
        else {
          if (!GetFileInformationByHandle(file, &info))
            result = GetLastError();
          else if (info.nNumberOfLinks != 1 ||
                   (info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT))
            result = DA_WORKSPACE_TREE_HAS_LINKS;
          CloseHandle(file);
        }
      }
      LocalFree(child);
      if (result != ERROR_SUCCESS)
        break;
    }
    if (!FindNextFileW(find, &entry)) {
      DWORD error = GetLastError();
      if (error != ERROR_NO_MORE_FILES)
        result = error;
      break;
    }
  }
  FindClose(find);
  return result;
}

static DWORD workspace_scan_links(HANDLE directory) {
  DWORD capacity = MAX_PATH + 1;
  WCHAR *path = NULL;
  for (;;) {
    path = LocalAlloc(LPTR, capacity * sizeof(WCHAR));
    if (!path)
      return ERROR_NOT_ENOUGH_MEMORY;
    DWORD length = GetFinalPathNameByHandleW(
        directory, path, capacity, FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
    if (length == 0) {
      DWORD error = GetLastError();
      LocalFree(path);
      return error;
    }
    if (length < capacity)
      break;
    LocalFree(path);
    capacity = length + 1;
  }
  DWORD result = workspace_scan_directory(path, 0);
  LocalFree(path);
  return result;
}

DWORD da_workspace_permissions_restore(WorkspacePermissions *snapshot) {
  if (!snapshot)
    return ERROR_INVALID_HANDLE;
  BOOL same = FALSE;
  snapshot->rewritten = FALSE;
  DWORD result = workspace_compare(snapshot, &same);
  if (result != ERROR_SUCCESS)
    return result;
  /* Owner, DACL and control already match: nothing to restore, nothing to
   * propagate (a rewrite would also touch every child needlessly). */
  if (same)
    return ERROR_SUCCESS;
  /* Known residual window (documented, low risk): a link created by a process
   * that escaped the Job between this scan and the propagation below is not
   * seen. The Job is already empty here, so only foreign users' processes
   * could do it. */
  result = workspace_scan_links(snapshot->directory);
  BOOL links = result == DA_WORKSPACE_TREE_HAS_LINKS;
  /* A scan failure still restores the ROOT (no propagation) and then reports
   * the scan error, so the caller sees a cause instead of a stale root. */
  DWORD scan_error =
      (result != ERROR_SUCCESS && !links) ? result : ERROR_SUCCESS;
  snapshot->rewritten = TRUE;
  result =
      workspace_descriptor_restore(snapshot->directory, snapshot->descriptor,
                                   !links && scan_error == ERROR_SUCCESS);
  if (result == ERROR_SUCCESS)
    result = workspace_compare(snapshot, &same);
  if (result == ERROR_SUCCESS && !same)
    result = ERROR_INVALID_SECURITY_DESCR;
  /* The root is back, but the children were not touched: visible code. */
  if (result == ERROR_SUCCESS && links)
    result = DA_WORKSPACE_TREE_HAS_LINKS;
  if (result == ERROR_SUCCESS && scan_error != ERROR_SUCCESS)
    result = scan_error;
  return result;
}

/* Stable object identity of the retained directory: volume serial plus the
 * 128-bit file id, hex. Lets a later explicit repair prove it targets the very
 * directory that failed, not another one that now has the same name. */
static DWORD workspace_handle_identity(HANDLE directory, char *output,
                                       DWORD capacity) {
  FILE_ID_INFO info;
  static const char digits[] = "0123456789abcdef";
  if (!output || capacity < 16 + 1 + 32 + 1)
    return ERROR_INSUFFICIENT_BUFFER;
  if (!GetFileInformationByHandleEx(directory, FileIdInfo, &info, sizeof(info)))
    return GetLastError();
  DWORD used = 0;
  for (int shift = 60; shift >= 0; shift -= 4)
    output[used++] = digits[(info.VolumeSerialNumber >> shift) & 0xf];
  output[used++] = '-';
  for (DWORD i = 0; i < sizeof(info.FileId.Identifier); ++i) {
    output[used++] = digits[info.FileId.Identifier[i] >> 4];
    output[used++] = digits[info.FileId.Identifier[i] & 0xf];
  }
  output[used] = '\0';
  return ERROR_SUCCESS;
}

DWORD da_workspace_permissions_identity(WorkspacePermissions *snapshot,
                                        char *output, DWORD capacity) {
  if (!snapshot)
    return ERROR_INVALID_HANDLE;
  return workspace_handle_identity(snapshot->directory, output, capacity);
}

/* TRUE when the last restore had to rewrite the descriptor. */
BOOL da_workspace_permissions_rewritten(WorkspacePermissions *snapshot) {
  return snapshot && snapshot->rewritten;
}

/* The retained handle itself, for ACL gates that must not reopen the path. */
HANDLE da_workspace_permissions_handle(WorkspacePermissions *snapshot) {
  return snapshot ? snapshot->directory : INVALID_HANDLE_VALUE;
}

DWORD da_workspace_identity(const WCHAR *path, char *output, DWORD capacity) {
  HANDLE directory = INVALID_HANDLE_VALUE;
  DWORD result = workspace_directory_open(path, 0, &directory);
  if (result == ERROR_SUCCESS)
    result = workspace_handle_identity(directory, output, capacity);
  if (directory != INVALID_HANDLE_VALUE)
    CloseHandle(directory);
  return result;
}

DWORD da_workspace_permissions_sddl(WorkspacePermissions *snapshot,
                                    LPSTR *output) {
  *output = NULL;
  if (!snapshot)
    return ERROR_INVALID_HANDLE;
  PSECURITY_DESCRIPTOR descriptor = NULL;
  DWORD result =
      GetSecurityInfo(snapshot->directory, SE_FILE_OBJECT,
                      OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION,
                      NULL, NULL, NULL, NULL, &descriptor);
  if (result == ERROR_SUCCESS)
    result = workspace_descriptor_sddl(descriptor, output);
  if (descriptor)
    LocalFree(descriptor);
  return result;
}

DWORD da_workspace_restore_private(const WCHAR *path) {
  HANDLE directory = INVALID_HANDLE_VALUE;
  PrivateDirectoryDescriptor value = {0};
  DWORD result = workspace_directory_open(path, READ_CONTROL, &directory);
  if (result == ERROR_SUCCESS)
    result = private_directory_descriptor(&value);
  /* Same rules as restoring a capture: with links in the tree, or when the scan
   * itself fails, only the root is rewritten and a visible code is returned. */
  BOOL links = FALSE;
  DWORD scan_error = ERROR_SUCCESS;
  if (result == ERROR_SUCCESS) {
    result = workspace_scan_links(directory);
    links = result == DA_WORKSPACE_TREE_HAS_LINKS;
    if (result != ERROR_SUCCESS && !links)
      scan_error = result;
    if (result != ERROR_SUCCESS)
      result = ERROR_SUCCESS;
  }
  if (result == ERROR_SUCCESS)
    result = workspace_descriptor_restore(
        directory, &value.descriptor, !links && scan_error == ERROR_SUCCESS);
  if (result == ERROR_SUCCESS && links)
    result = DA_WORKSPACE_TREE_HAS_LINKS;
  if (result == ERROR_SUCCESS && scan_error != ERROR_SUCCESS)
    result = scan_error;
  private_directory_descriptor_free(&value);
  if (directory != INVALID_HANDLE_VALUE)
    CloseHandle(directory);
  return result;
}

static DWORD workspace_writer_name(PSID sid, const CodexSandbox *sandbox,
                                   char *output, DWORD capacity) {
  if (sandbox->present && EqualSid(sid, (PSID)sandbox->group)) {
    const char *name = "CodexSandboxUsers";
    if (strlen(name) + 1 > capacity)
      return ERROR_INSUFFICIENT_BUFFER;
    memcpy(output, name, strlen(name) + 1);
    return ERROR_SUCCESS;
  }
  WCHAR name[256], domain[256], qualified[514];
  DWORD name_size = ARRAYSIZE(name), domain_size = ARRAYSIZE(domain);
  SID_NAME_USE type;
  if (!LookupAccountSidW(NULL, sid, name, &name_size, domain, &domain_size,
                         &type)) {
    DWORD result = GetLastError();
    if (result != ERROR_NONE_MAPPED)
      return result;
    const char *unknown = "SID sint\xc3\xa9tico sin cuenta";
    if (strlen(unknown) + 1 > capacity)
      return ERROR_INSUFFICIENT_BUFFER;
    memcpy(output, unknown, strlen(unknown) + 1);
    return ERROR_SUCCESS;
  }
  if (swprintf_s(qualified, ARRAYSIZE(qualified),
                 domain[0] ? L"%ls\\%ls" : L"%ls%ls", domain, name) < 0)
    return ERROR_INSUFFICIENT_BUFFER;
  if (!WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, qualified, -1, output,
                           (int)capacity, NULL, NULL))
    return GetLastError();
  return ERROR_SUCCESS;
}

static DWORD workspace_writers_descriptor(PSECURITY_DESCRIPTOR descriptor,
                                          char *output, DWORD capacity) {
  CodexSandbox sandbox = {0};
  PACL acl;
  PSID owner;
  BOOL present, defaulted;
  DWORD result = ERROR_SUCCESS, used = 0;
  if (!capacity)
    return ERROR_INSUFFICIENT_BUFFER;
  output[0] = '\0';
  if (!GetSecurityDescriptorOwner(descriptor, &owner, &defaulted) ||
      !GetSecurityDescriptorDacl(descriptor, &present, &acl, &defaulted))
    return GetLastError();
  if (!codex_sandbox_load(&sandbox, NULL)) {
    result = GetLastError();
    if (!result)
      result = ERROR_INVALID_SID;
    goto done;
  }
  if (!present || !acl) {
    const char *all = "Todos (DACL abierta)\n";
    if (strlen(all) + 1 > capacity) {
      result = ERROR_INSUFFICIENT_BUFFER;
      goto done;
    }
    memcpy(output, all, strlen(all) + 1);
    goto done;
  }
  /* The owner has implicit WRITE_DAC, even without a write ACE. List every
   * effective writer, once per SID, without emitting raw SID strings. */
  for (DWORD i = 0; i <= acl->AceCount; ++i) {
    PSID sid = owner;
    if (i) {
      ACCESS_ALLOWED_ACE *ace;
      if (!GetAce(acl, i - 1, (void **)&ace)) {
        result = GetLastError();
        goto done;
      }
      if (ace->Header.AceFlags & INHERIT_ONLY_ACE)
        continue;
      if (ace->Header.AceType != ACCESS_ALLOWED_ACE_TYPE) {
        if (ace->Header.AceType == ACCESS_ALLOWED_OBJECT_ACE_TYPE ||
            ace->Header.AceType == ACCESS_ALLOWED_CALLBACK_ACE_TYPE ||
            ace->Header.AceType == ACCESS_ALLOWED_CALLBACK_OBJECT_ACE_TYPE) {
          result = ERROR_NOT_SUPPORTED;
          goto done;
        }
        continue;
      }
      sid = &ace->SidStart;
      if (ace->Header.AceSize < sizeof(ACCESS_ALLOWED_ACE) ||
          !IsValidSid(sid) ||
          GetLengthSid(sid) > ace->Header.AceSize -
                                  FIELD_OFFSET(ACCESS_ALLOWED_ACE, SidStart)) {
        result = ERROR_INVALID_ACL;
        goto done;
      }
      if (owner && EqualSid(sid, owner))
        continue;
      BOOL duplicate = FALSE;
      for (DWORD j = 0; j + 1 < i; ++j) {
        ACCESS_ALLOWED_ACE *previous;
        if (!GetAce(acl, j, (void **)&previous)) {
          result = GetLastError();
          goto done;
        }
        if (previous->Header.AceType == ACCESS_ALLOWED_ACE_TYPE &&
            !(previous->Header.AceFlags & INHERIT_ONLY_ACE) &&
            EqualSid(sid, &previous->SidStart)) {
          duplicate = TRUE;
          break;
        }
      }
      if (duplicate)
        continue;
      int writer = acl_effective_writer(acl, sid);
      if (writer < 0) {
        result = ERROR_INVALID_ACL;
        goto done;
      }
      if (!writer)
        continue;
    }
    if (!sid || !IsValidSid(sid)) {
      result = ERROR_INVALID_SID;
      goto done;
    }
    char label[2048];
    result = workspace_writer_name(sid, &sandbox, label, sizeof(label));
    if (result != ERROR_SUCCESS)
      goto done;
    size_t length = strlen(label);
    if (length + 2 > capacity - used) {
      result = ERROR_INSUFFICIENT_BUFFER;
      goto done;
    }
    memcpy(output + used, label, length);
    used += (DWORD)length;
    output[used++] = '\n';
    output[used] = '\0';
  }
done:
  codex_sandbox_free(&sandbox);
  if (result != ERROR_SUCCESS)
    output[0] = '\0';
  return result;
}

DWORD da_workspace_writers(const WCHAR *path, char *output, DWORD capacity) {
  HANDLE directory = INVALID_HANDLE_VALUE;
  PSECURITY_DESCRIPTOR descriptor = NULL;
  DWORD result = workspace_directory_open(path, READ_CONTROL, &directory);
  if (result == ERROR_SUCCESS)
    result =
        GetSecurityInfo(directory, SE_FILE_OBJECT,
                        OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION,
                        NULL, NULL, NULL, NULL, &descriptor);
  if (result == ERROR_SUCCESS)
    result = workspace_writers_descriptor(descriptor, output, capacity);
  if (descriptor)
    LocalFree(descriptor);
  if (directory != INVALID_HANDLE_VALUE)
    CloseHandle(directory);
  return result;
}

#ifdef DA_TEST_SEAMS
/* Win32 test seam: mutate the same retained object, never reopen its path. */
DWORD da_workspace_permissions_test_set(WorkspacePermissions *snapshot,
                                        const WCHAR *sddl) {
  if (!snapshot)
    return ERROR_INVALID_HANDLE;
  PSECURITY_DESCRIPTOR descriptor = NULL;
  if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(
          sddl, SDDL_REVISION_1, &descriptor, NULL))
    return GetLastError();
  DWORD result =
      workspace_descriptor_restore(snapshot->directory, descriptor, TRUE);
  LocalFree(descriptor);
  return result;
}

/* Owner/DACL SDDL of any file or directory, without following reparse points:
 * lets tests prove that objects OUTSIDE a workspace were never touched. */
DWORD da_workspace_test_path_sddl(const WCHAR *path, LPSTR *output) {
  *output = NULL;
  HANDLE object = CreateFileW(
      path, READ_CONTROL,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL,
      OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT,
      NULL);
  if (object == INVALID_HANDLE_VALUE)
    return GetLastError();
  PSECURITY_DESCRIPTOR descriptor = NULL;
  DWORD result =
      GetSecurityInfo(object, SE_FILE_OBJECT,
                      OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION,
                      NULL, NULL, NULL, NULL, &descriptor);
  CloseHandle(object);
  if (result == ERROR_SUCCESS)
    result = workspace_descriptor_sddl(descriptor, output);
  if (descriptor)
    LocalFree(descriptor);
  return result;
}

DWORD da_workspace_writers_test_sddl(const WCHAR *sddl, char *output,
                                     DWORD capacity) {
  PSECURITY_DESCRIPTOR descriptor = NULL;
  if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(
          sddl, SDDL_REVISION_1, &descriptor, NULL))
    return GetLastError();
  DWORD result = workspace_writers_descriptor(descriptor, output, capacity);
  LocalFree(descriptor);
  return result;
}
#endif /* DA_TEST_SEAMS */
