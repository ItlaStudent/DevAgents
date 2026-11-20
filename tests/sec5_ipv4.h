/* IANA IPv4 Special-Purpose Address Registry, retrieved 2026-10-14:
   https://www.iana.org/assignments/iana-ipv4-special-registry/
   Global unicast classification only, not ownership or reachability proof. */
#ifndef SEC5_IPV4_H
#define SEC5_IPV4_H
#include <stdint.h>
static inline int sec5_global_ipv4(uint32_t ip) {
  /* Globally reachable /32 exceptions inside the non-global 192.0.0.0/24. */
  if (ip == 0xc0000009u || ip == 0xc000000au)
    return 1;
  static const struct {
    uint32_t network, mask;
  } nonglobal[] = {
      {0x00000000u, 0xff000000u}, /* 0/8, includes 0.0.0.0/32 */
      {0x0a000000u, 0xff000000u}, /* 10/8 */
      {0x64400000u, 0xffc00000u}, /* 100.64/10 */
      {0x7f000000u, 0xff000000u}, /* 127/8 */
      {0xa9fe0000u, 0xffff0000u}, /* 169.254/16 */
      {0xac100000u, 0xfff00000u}, /* 172.16/12 */
      {0xc0000000u, 0xffffff00u}, /* 192.0.0/24, includes /29, .8, .170/.171 */
      {0xc0000200u, 0xffffff00u}, /* 192.0.2/24 */
      {0xc0586300u,
       0xffffff00u}, /* 192.88.99/24 deprecated; .2/32 non-global */
      {0xc0a80000u, 0xffff0000u}, /* 192.168/16 */
      {0xc6120000u, 0xfffe0000u}, /* 198.18/15 */
      {0xc6336400u, 0xffffff00u}, /* 198.51.100/24 */
      {0xcb007100u, 0xffffff00u}, /* 203.0.113/24 */
      {0xe0000000u,
       0xe0000000u}, /* Multicast 224/4 + reserved 240/4, broadcast */
  };
  for (unsigned i = 0; i < sizeof(nonglobal) / sizeof(nonglobal[0]); ++i)
    if ((ip & nonglobal[i].mask) == nonglobal[i].network)
      return 0;
  return 1;
}
#endif
