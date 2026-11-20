#pragma once
#include <cstdio>
#include <cstdlib>

// Always evaluate the expression, including builds with NDEBUG.
#define DA_CHECK(expression)                                                   \
  do {                                                                         \
    if (!(expression)) {                                                       \
      std::fprintf(stderr, "%s:%d: check failed: %s\n", __FILE__, __LINE__,    \
                   #expression);                                               \
      std::abort();                                                            \
    }                                                                          \
  } while (false)
