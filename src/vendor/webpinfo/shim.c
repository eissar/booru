// In-memory webpinfo -diag validation, without CLI output or file I/O.
#include "webpinfo.c"

// Returns WebPInfoStatus (0 = OK). Warnings alone do not fail, just as in
// webpinfo -diag. This checks container/headers, not full pixel decoding.
// Input remains caller-owned. All mutable validator state is invocation-local.
int webpinfo_inspect(const uint8_t* data, size_t size, int* has_alpha) {
  WebPInfo info;
  WebPData input;
  if (has_alpha != NULL) *has_alpha = 0;
  if (data == NULL) return WEBP_INFO_INVALID_PARAM;
  WebPInfoInit(&info);
  info.quiet = 1;
  // -diag only controls printed diagnostics, not validation decisions.
  input.bytes = data;
  input.size = size;
  const int status = (int)AnalyzeWebP(&info, &input);
  if (status == WEBP_INFO_OK && has_alpha != NULL) *has_alpha = info.has_alpha;
  return status;
}

int webpinfo_validate(const uint8_t* data, size_t size) {
  return webpinfo_inspect(data, size, NULL);
}
