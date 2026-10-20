// In-memory webpinfo -diag validation, without CLI output or file I/O.
#include "webpinfo.c"

// Returns WebPInfoStatus (0 = OK). Warnings alone do not fail, just as in
// webpinfo -diag. This checks container/headers, not full pixel decoding.
// Input remains caller-owned. All mutable validator state is invocation-local.
int webpinfo_validate(const uint8_t* data, size_t size) {
  WebPInfo info;
  WebPData input;
  if (data == NULL) return WEBP_INFO_INVALID_PARAM;
  WebPInfoInit(&info);
  info.quiet = 1;
  // -diag only controls printed diagnostics, not validation decisions.
  input.bytes = data;
  input.size = size;
  return (int)AnalyzeWebP(&info, &input);
}
