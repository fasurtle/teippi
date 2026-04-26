/* GCC 13 compatibility header for teippi.
   Force-included via -include gcc13_compat.h during compilation.
   Adds missing standard library includes that GCC 13 no longer transitively
   pulls in, and silences warnings that became errors in newer toolchains. */
#pragma once
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <string>
#include <stdexcept>
