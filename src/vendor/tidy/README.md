# HTML Tidy 5.8.0

Minimal public C API bindings, built from the official htacg/tidy-html5 tag:
https://github.com/htacg/tidy-html5/archive/refs/tags/5.8.0.tar.gz

Archive SHA-256: `59c86d5b2e452f63c5cdb29c866a12a4c55b1741d7025cf2f3ce0cde99b0660e`.
License: `LICENSE` (upstream `README/LICENSE.txt`).

`Bool` is a C **enum**, represented by `c.int`, not an 8-bit boolean.
`SaveString` reports the output byte count without a trailing NUL. A size
probe with zero capacity returns -ENOMEM; allocate the reported size and retry.
Parse/repair/save return negative values on failure, 0 on success, and positive
values for diagnostics. Release every created document.

## Normalization contract

Keep the options in `src/template/normalize_html_test.odin` unchanged:
`sort-attributes=alpha`, `wrap=0`, `indent=0`, `tidy-mark=0`,
`merge-divs=0`, `merge-spans=0`. Pass these names to `OptParseValue`.
Do not enable body-only output or other cleanup options. Native default newlines differ across platforms;
callers comparing serialized bytes across platforms must account for this.

## Linux x64

The system has `libtidy.so.58`, but no unversioned development linker library.
The binding therefore includes a locally built shared library rather than
requiring a development package or an absolute system path.

```sh
cmake -S tidy-html5-5.8.0 -B tidy-linux-build \
  -DCMAKE_BUILD_TYPE=Release -DSUPPORT_CONSOLE_APP=OFF -DBUILD_SHARED_LIB=ON
cmake --build tidy-linux-build -j4
cp tidy-linux-build/libtidy.so.5.8.0 src/vendor/tidy/linux-amd64/libtidy.so
```

Built with the host GCC/CMake toolchain. Shared object SHA-256:
`8f508b3a9438fceaddb99a5068b724bb8a9cdfcfe8a66f70423507c106e581eb`.
Its SONAME is `libtidy.so.58`; deploy it with that name in a loader search path
(or install the system runtime). The checked-in filename is the link input.

## Windows x64

Clang/LLVM 19.1.7, `x86_64-pc-windows-msvc` target, static MSVC CRT;
no Tidy DLL. Use the same xwin SDK/CRT setup as dav1d in
`../WINDOWS.md`. From the repository root, with the extracted source at
`/tmp/tidy-html5-5.8.0`:

```sh
set -e
sdk="$HOME/.xwin" # absolute path to xwin splat output
src=/tmp/tidy-html5-5.8.0
obj="$(mktemp -d)"
for f in "$src"/src/*.c; do
  clang-19 --target=x86_64-pc-windows-msvc -fms-runtime-lib=static \
    -O2 -DNDEBUG -DTIDY_STATIC \
    -DLIBTIDY_VERSION='"5.8.0"' -DRELEASE_DATE='"2021/07/10"' \
    -isystem "$sdk/crt/include" -isystem "$sdk/sdk/include/ucrt" \
    -isystem "$sdk/sdk/include/shared" -isystem "$sdk/sdk/include/um" \
    -I"$src/include" -I"$src/src" \
    -c "$f" -o "$obj/$(basename "$f" .c).obj"
done
llvm-ar-19 rcs "$obj/tidy.lib" "$obj"/*.obj
cp "$obj/tidy.lib" src/vendor/tidy/windows-amd64/tidy.lib
rm -r "$obj"
```

`NDEBUG` disables upstream debug tracing. Upstream config.c emits four
discarded-const warnings; language headers emit eight unknown-pragma warnings.
COFF directives include `/DEFAULTLIB:libcmt.lib` and
`/DEFAULTLIB:oldnames.lib`, matching the static CRT used by dav1d/WebP.
The previous GNU Windows build used an incompatible CRT.

Validation: `timeout --kill-after=10s 120s bash test/tools/windows.sh`
linked successfully and ran all 45 tests under Wine, exiting 1 with three
failures (not a timeout): `test.import_browse_delete_replay` (GET /gallery
returned 0 instead of 200), `thumbnail.generate_missing_fixture_thumbnails`
(missing-source reporting), and `thumbnail.stream_webp_socket_batches`
(external command status). No test fixes were made.
