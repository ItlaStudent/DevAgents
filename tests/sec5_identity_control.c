#include "sec5_identity.h"
#include "sec5_ipv4.h"
#include <stdio.h>
#include <string.h>

static BOOL ipv4_control(void) {
  static const struct {
    uint32_t first, last;
  } blocked[] = {
      {0x00000000u, 0x00ffffffu}, {0x0a000000u, 0x0affffffu},
      {0x64400000u, 0x647fffffu}, {0x7f000000u, 0x7fffffffu},
      {0xa9fe0000u, 0xa9feffffu}, {0xac100000u, 0xac1fffffu},
      {0xc0000000u, 0xc00000ffu}, {0xc0000200u, 0xc00002ffu},
      {0xc0586300u, 0xc05863ffu}, {0xc0a80000u, 0xc0a8ffffu},
      {0xc6120000u, 0xc613ffffu}, {0xc6336400u, 0xc63364ffu},
      {0xcb007100u, 0xcb0071ffu}, {0xe0000000u, 0xffffffffu},
  };
  static const uint32_t global[] = {
      0x01010101u, 0x08080808u, 0x643fffffu, 0x64800000u,
      0xac0fffffu, 0xac200000u, 0xc0000009u, 0xc000000au,
      0xc01fc400u, 0xc034c100u, 0xc0af3000u, 0xc05862ffu,
      0xc0586400u, 0xc611ffffu, 0xc6140000u, 0xdfffffffu,
  };
  unsigned tested = 0, failed = 0;
  for (unsigned i = 0; i < sizeof(blocked) / sizeof(blocked[0]); ++i) {
    uint32_t endpoints[] = {blocked[i].first, blocked[i].last};
    for (unsigned j = 0; j < 2; ++j) {
      int actual = sec5_global_ipv4(endpoints[j]);
      ++tested;
      failed += actual != 0;
      printf("IPV4_CONTROL ip=0x%08lx expected=0 global=%d\n",
             (unsigned long)endpoints[j], actual);
    }
  }
  for (unsigned i = 0; i < sizeof(global) / sizeof(global[0]); ++i) {
    int actual = sec5_global_ipv4(global[i]);
    ++tested;
    failed += actual != 1;
    printf("IPV4_CONTROL ip=0x%08lx expected=1 global=%d\n",
           (unsigned long)global[i], actual);
  }
  /* Non-global specific assignments and multicast/reserved boundary. */
  const uint32_t special[] = {0xc0000008u, 0xc00000aau, 0xc00000abu,
                              0xc0586302u, 0xefffffffu, 0xf0000000u};
  for (unsigned i = 0; i < sizeof(special) / sizeof(special[0]); ++i) {
    ++tested;
    failed += sec5_global_ipv4(special[i]) != 0;
  }
  printf("IPV4_CONTROL tested=%u failed=%u NETWORK=NOT_EXECUTED\n", tested,
         failed);
  return failed == 0;
}

int main(int argc, char **argv) {
  BOOL legacy = argc == 2 && !strcmp(argv[1], "--legacy-pid");
  if (argc > 2 || (argc == 2 && !legacy))
    return 2;
  sec5_process_table table;
  FILETIME birth, exit, kernel, user;
  if (!GetProcessTimes(GetCurrentProcess(), &birth, &exit, &kernel, &user) ||
      !sec5_process_snapshot(&table)) {
    printf("IDENTITY_CONTROL snapshot_error=%lu\n", GetLastError());
    return 2;
  }
  const sec5_process_entry *foreign = NULL;
  unsigned self_matches = 0;
  for (unsigned i = 0; i < table.count; ++i) {
    const sec5_process_entry *entry = &table.entries[i];
    if (sec5_same_instance(entry->pid, entry->birth, GetCurrentProcessId(),
                           birth))
      ++self_matches;
    if (!foreign && entry->pid && entry->parent &&
        sec5_birth_known(entry->birth) &&
        CompareFileTime(&entry->birth, &birth) < 0) {
      foreign = entry;
    }
  }
  if (!foreign || self_matches != 1) {
    free(table.entries);
    printf("IDENTITY_CONTROL older_entry=%d self_matches=%u\n", foreign != NULL,
           self_matches);
    return 2;
  }
  /* Simulate only the pinned parent's PID. Both creation times and the
     candidate's PID/parent are real, captured from this system invocation. */
  DWORD simulated_parent = foreign->parent;
  int classified =
      legacy ? foreign->parent == simulated_parent
             : sec5_descendant_classify(foreign->parent, foreign->birth,
                                        simulated_parent, birth, exit, TRUE);
  FILETIME zero = {0}, later = birth;
  ULONGLONG ticks =
      ((ULONGLONG)birth.dwHighDateTime << 32) | birth.dwLowDateTime;
  later = sec5_filetime(ticks + 1);
  BOOL pin_rejected =
      !sec5_same_instance(foreign->pid, birth, foreign->pid, foreign->birth);
  BOOL guards =
      sec5_descendant_classify(simulated_parent, birth, simulated_parent, birth,
                               zero, TRUE) == 1 &&
      sec5_descendant_classify(simulated_parent, zero, simulated_parent, birth,
                               zero, TRUE) == -1 &&
      sec5_descendant_classify(simulated_parent, birth, simulated_parent, birth,
                               zero, FALSE) == -1 &&
      sec5_descendant_classify(simulated_parent, later, simulated_parent, birth,
                               birth, TRUE) == 0 &&
      sec5_same_instance(foreign->pid, foreign->birth, foreign->pid,
                         foreign->birth);
  printf("IDENTITY_CONTROL mode=%s snapshot_entries=%u candidate_pid=%lu "
         "real_parent_pid=%lu candidate_birth=%lu:%lu "
         "real_pinned_birth=%lu:%lu simulated_parent_pid=%lu "
         "legacy_descendant=1 classified=%d opened_candidate=0 "
         "reused_console_pin_rejected=%d guards=%d\n",
         legacy ? "legacy-pid" : "instance", table.count, foreign->pid,
         foreign->parent, foreign->birth.dwHighDateTime,
         foreign->birth.dwLowDateTime, birth.dwHighDateTime,
         birth.dwLowDateTime, simulated_parent, classified, pin_rejected,
         guards);
  free(table.entries);
  BOOL ipv4 = ipv4_control();
  BOOL good = classified == 0 && pin_rejected && guards && ipv4;
  printf("IDENTITY_CONTROL verdict=%s OS_ISOLATION=NOT_MEASURED\n",
         good ? "PASS" : "FAIL");
  return good ? 0 : 1;
}
