#include "origin_policy.hpp"
// Inject a flush failure only in this translation unit, after the real write.
static bool failApprovalFlush = false;
static bool approvalFlushReached = false;
static BOOL WINAPI ApprovalFlush(HANDLE file) {
  if (failApprovalFlush) {
    approvalFlushReached = true;
    SetLastError(ERROR_WRITE_FAULT);
    return FALSE;
  }
  return FlushFileBuffers(file);
}
#define FlushFileBuffers ApprovalFlush
#include "browser_policy.hpp"
#undef FlushFileBuffers
#include "preview_policy.hpp"
#include <cstdio>
#include <fstream>

static bool WriteLedger(const wchar_t *path, const std::vector<BYTE> &bytes) {
  std::ofstream file(path, std::ios::binary | std::ios::trunc);
  file.write(reinterpret_cast<const char *>(bytes.data()), bytes.size());
  file.close();
  return !file.fail();
}

int main() {
  struct Case {
    const wchar_t *url;
    bool allowed;
  };
  const Case cases[] = {
      {L"https://devagents.local", true},
      {L"https://devagents.local/index.html?ventana=2#chat", true},
      {L"https://DEVAGENTS.LOCAL:443/index.html", true},
      {L"https://devagents.local.evil.com", false},
      {L"https://devagents.local@evil.com", false},
      {L"http://devagents.local", false},
      {L"https://devagents.local:444", false},
      {L"https://devagents.local.", false},
      {L"file:///C:/payload.exe", false},
      {L"about:blank", false},
      {L"data:text/html,<script>alert(1)</script>", false},
      {L"javascript:alert(1)", false},
      {L"//devagents.local/index.html", false},
      {L"https://devagents.local\\@evil.com", false},
      {L"https://devagents%2elocal.evil.com", false},
      {L"https://devagents.local%2eevil.com", false},
      {L"https://xn--devagents-9jg.local", false},
      {L"https://@devagents.local", false},
      {L"https://:@devagents.local", false},
      {L"", false}};
  unsigned passed = 0;
  wchar_t temp[MAX_PATH]{}, ledger[MAX_PATH]{};
  if (!GetTempPathW(MAX_PATH, temp) ||
      !GetTempFileNameW(temp, L"bpo", 0, ledger)) {
    std::fputs("FAIL isolated approval fixture creation\n", stderr);
    return 1;
  }
  beats::browser::Policy persisted;
  const bool approved = persisted.Approve(L"https://example.com/page", ledger);
  beats::browser::Policy restored;
  const bool restoredOk = restored.Load(ledger) &&
                          restored.Allows(L"https://example.com/other") &&
                          !restored.Allows(L"https://sub.example.com") &&
                          !restored.Allows(L"http://example.com") &&
                          !restored.Allows(L"https://example.com:444");
  std::ifstream originalFile(ledger, std::ios::binary);
  const std::vector<BYTE> original(
      (std::istreambuf_iterator<char>(originalFile)),
      std::istreambuf_iterator<char>());
  originalFile.close();
  std::wstring linked = std::wstring(ledger) + L"-link";
  const bool madeLink = CreateHardLinkW(linked.c_str(), ledger, nullptr);
  beats::browser::Policy linkedPolicy;
  const bool linkDenied =
      madeLink && !linkedPolicy.Load(linked) &&
      !linkedPolicy.Approve(L"https://other.example.com", linked);
  if (madeLink)
    DeleteFileW(linked.c_str());
  const HANDLE append = CreateFileW(ledger, FILE_APPEND_DATA, 0, nullptr,
                                    OPEN_EXISTING, 0, nullptr);
  const std::wstring injected = L"https://injected.example:443\n";
  DWORD added = 0;
  const bool injectedOk =
      append != INVALID_HANDLE_VALUE &&
      WriteFile(append, injected.data(),
                static_cast<DWORD>(injected.size() * sizeof(wchar_t)), &added,
                nullptr) &&
      added == injected.size() * sizeof(wchar_t);
  if (append != INVALID_HANDLE_VALUE)
    CloseHandle(append);
  // Reuse a policy with approvals: a failed reload must clear stale grants too.
  const bool injectionDenied = injectedOk && !restored.Load(ledger) &&
                               !restored.Allows(L"https://injected.example") &&
                               !restored.Allows(L"https://example.com");
  if (!injectionDenied) {
    DeleteFileW(ledger);
    std::fputs("FAIL ledger appended line restored approvals without consent\n",
               stderr);
    return 1;
  }
  std::puts("PASS ledger appended line: zero restored approvals");
  beats::browser::Policy atomic, reloaded;
  const bool atomicReady = WriteLedger(ledger, original) && atomic.Load(ledger);
  failApprovalFlush = true;
  const bool failedApproval =
      !atomic.Approve(L"https://atomic-new.example", ledger);
  failApprovalFlush = false;
  std::ifstream afterFile(ledger, std::ios::binary);
  const std::vector<BYTE> after((std::istreambuf_iterator<char>(afterFile)),
                                std::istreambuf_iterator<char>());
  afterFile.close();
  WIN32_FIND_DATAW pending{};
  const HANDLE leftover =
      FindFirstFileW((std::wstring(ledger) + L".tmp-*").c_str(), &pending);
  const bool cleaned = leftover == INVALID_HANDLE_VALUE &&
                       GetLastError() == ERROR_FILE_NOT_FOUND;
  if (leftover != INVALID_HANDLE_VALUE)
    FindClose(leftover);
  const bool atomicOk =
      atomicReady && approvalFlushReached && failedApproval &&
      after == original && cleaned && atomic.Allows(L"https://example.com") &&
      !atomic.Allows(L"https://atomic-new.example") && reloaded.Load(ledger) &&
      reloaded.Allows(L"https://example.com") &&
      !reloaded.Allows(L"https://atomic-new.example");
  std::printf("%s ledger atomic flush failure: previous bytes preserved, old "
              "approval reloads, new approval absent, temporary removed\n",
              atomicOk ? "PASS" : "FAIL");
  if (!atomicOk) {
    DeleteFileW(ledger);
    return 1;
  }
  auto reject = [&](const char *label, const std::vector<BYTE> &bytes) {
    beats::browser::Policy tested;
    const bool ok = WriteLedger(ledger, original) && tested.Load(ledger) &&
                    tested.Allows(L"https://example.com") &&
                    WriteLedger(ledger, bytes) && !tested.Load(ledger) &&
                    tested.ConnectionAllowlist() == L"();webrtc=block";
    std::printf("%s ledger %s: zero restored approvals\n", ok ? "PASS" : "FAIL",
                label);
    return ok;
  };
  if (original.size() < 32) {
    DeleteFileW(ledger);
    return 1;
  }
  auto changed = original;
  changed[changed.size() / 2] ^= 0x40;
  auto truncated = original;
  truncated.resize(truncated.size() - 8);
  const bool changedDenied = reject("changed line/ciphertext", changed);
  const bool truncatedDenied = reject("truncated file", truncated);
  // A valid DPAPI blob from another product key/entropy must also be rejected.
  char otherKey[] = "Different.Product.OriginApproval.v1";
  std::wstring foreignText = L"https://example.com:443\n";
  DATA_BLOB input{static_cast<DWORD>(foreignText.size() * sizeof(wchar_t)),
                  reinterpret_cast<BYTE *>(foreignText.data())};
  DATA_BLOB entropy{sizeof(otherKey), reinterpret_cast<BYTE *>(otherKey)},
      blob{};
  bool foreignDenied = false;
  if (CryptProtectData(&input, nullptr, &entropy, nullptr, nullptr,
                       CRYPTPROTECT_UI_FORBIDDEN, &blob)) {
    std::vector<BYTE> foreign(12 + blob.cbData);
    std::memcpy(foreign.data(), original.data(), 8);
    std::memcpy(foreign.data() + 8, &blob.cbData, sizeof(DWORD));
    std::memcpy(foreign.data() + 12, blob.pbData, blob.cbData);
    LocalFree(blob.pbData);
    foreignDenied = reject("other protection key", foreign);
  }
  std::wstring plainText = L"https://example.com:443\n";
  const auto *plainBytes = reinterpret_cast<const BYTE *>(plainText.data());
  const bool plainDenied =
      reject("legacy plaintext",
             std::vector<BYTE>(plainBytes, plainBytes + plainText.size() *
                                                            sizeof(wchar_t)));
  beats::browser::Policy locked;
  const bool lockReady = WriteLedger(ledger, original) && locked.Load(ledger);
  const HANDLE exclusive =
      CreateFileW(ledger, GENERIC_READ, 0, nullptr, OPEN_EXISTING, 0, nullptr);
  const bool unreadableDenied =
      lockReady && exclusive != INVALID_HANDLE_VALUE && !locked.Load(ledger) &&
      locked.ConnectionAllowlist() == L"();webrtc=block";
  if (exclusive != INVALID_HANDLE_VALUE)
    CloseHandle(exclusive);
  std::printf("%s ledger unreadable: zero restored approvals\n",
              unreadableDenied ? "PASS" : "FAIL");
  DeleteFileW(ledger);
  if (!changedDenied || !truncatedDenied || !foreignDenied || !plainDenied ||
      !unreadableDenied)
    return 1;
  const std::string protocol =
      "{\"request\":{\"url\":\"https://"
      "example.com\",\"isSameSite\":true},\"optional\":null}";
  beats::preview::Value value;
  if (!approved || !restoredOk || !linkDenied ||
      beats::preview::Parser(protocol, true).Parse(value) ||
      !beats::preview::Parser(protocol, true, true).Parse(value)) {
    std::fputs(
        "FAIL approval persistence, hardlink rejection or protocol JSON\n",
        stderr);
    return 1;
  }
  std::puts("PASS browser approvals: persisted exact origin, other "
            "scheme/port/subdomain denied, linked ledger denied; "
            "strict/protocol JSON separated");
  // 10-nov: Fetch.requestPaused from Chromium 157 carries 20+ request headers
  // once a site asks for client hints. The page-reachable default (16 keys)
  // must still reject it; the runtime-event limits must accept it.
  {
    std::string headers;
    for (int i = 0; i < 24; ++i)
      headers += std::string(i ? "," : "") + "\"sec-ch-h" + std::to_string(i) +
                 "\":\"v\"";
    const std::string paused =
        "{\"requestId\":\"1\",\"resourceType\":\"Document\",\"request\":{"
        "\"url\":\"https://www.google.com/\",\"headers\":{" +
        headers + "}}}";
    beats::preview::Value narrow, wide;
    if (beats::preview::Parser(paused, true, true).Parse(narrow) ||
        !beats::preview::Parser(paused, true, true,
                                beats::preview::MessageLimit, 4, 256, 512)
             .Parse(wide)) {
      std::fputs("FAIL protocol event key limit\n", stderr);
      return 1;
    }
  }
  beats::browser::Policy panel;
  if (!beats::browser::Policy::StaticAssetPath("index.html") ||
      !beats::browser::Policy::StaticAssetPath("assets/main.js") ||
      beats::browser::Policy::StaticAssetPath(".env") ||
      beats::browser::Policy::StaticAssetPath(".git/config") ||
      beats::browser::Policy::StaticAssetPath("auth.json") ||
      beats::browser::Policy::StaticAssetPath("keys.txt") ||
      beats::browser::Policy::StaticAssetPath("assets/.cache/app.js"))
    return 1;
  if (panel.Allows(L"https://example.com") ||
      panel.Allows(L"https://devagents.local") ||
      panel.RegisterApp(L"http://example.com:8100") ||
      !panel.RegisterApp(L"http://localhost:8100") ||
      !panel.Allows(L"http://localhost:8100/form") ||
      panel.Allows(L"http://localhost:8101") ||
      panel.Allows(L"http://127.0.0.1:8100") ||
      panel.Allows(L"ws://localhost:8100") ||
      panel.Allows(L"file:///C:/private.txt") ||
      panel.Approve(L"https://devagents.local", L"") ||
      beats::browser::Policy::Origin(L"https://USER:PASS@example.com") != L"" ||
      beats::browser::Policy::Origin(L"https://EXAMPLE.COM/a") !=
          L"https://example.com:443" ||
      beats::browser::Policy::RuntimeSupportsIsolation(L"151.0.1.0") ||
      !beats::browser::Policy::RuntimeSupportsIsolation(L"152.0.1.0")) {
    std::fputs("FAIL integrated browser exact-origin/isolation policy\n",
               stderr);
    return 1;
  }
  for (const auto &entry : cases) {
    if (beats::security::IsAppOrigin(entry.url) != entry.allowed) {
      std::fwprintf(stderr, L"FAIL origin: %ls\n", entry.url);
      return 1;
    }
    ++passed;
  }
  if (!beats::security::IsBrowserUrl(L"https://example.com/a", true) ||
      !beats::security::IsBrowserUrl(L"http://example.com/a") ||
      beats::security::IsBrowserUrl(L"http://example.com/a", true) ||
      beats::security::IsBrowserUrl(L"file:///C:/payload.exe") ||
      beats::security::IsBrowserUrl(L"https://user:pass@example.com") ||
      beats::security::IsBrowserUrl(
          std::wstring_view(L"https://example.com\0.evil", 25))) {
    std::fputs("FAIL browser URL policy\n", stderr);
    return 1;
  }
  std::printf("PASS origin policy: %u exact-origin cases; browser URL policy\n",
              passed);
  return 0;
}
