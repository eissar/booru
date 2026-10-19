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

Keep the options in `test/html-fixture-tdd/compare_html.pl` unchanged:
`sort-attributes=alpha`, `wrap=0`, `indent=0`, `tidy-mark=0`,
`merge-divs=0`, `merge-spans=0`. Pass these names to `OptParseValue`
(the Perl wrapper spells option names with underscores). Do not enable body-only
output or other cleanup options. Native default newlines differ across platforms;
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

Zig 0.17.0, GNU Windows target; static archive, no Tidy DLL:

```sh
mkdir -p tidy-win-obj
for f in tidy-html5-5.8.0/src/*.c; do
  zig cc -target x86_64-windows-gnu -O2 -DTIDY_STATIC \
    -DLIBTIDY_VERSION='"5.8.0"' -DRELEASE_DATE='"2021/07/10"' \
    -Itidy-html5-5.8.0/include -Itidy-html5-5.8.0/src \
    -c "$f" -o "tidy-win-obj/$(basename "$f" .c).o" || exit
 done
zig ar rcs src/vendor/tidy/windows-amd64/tidy.lib tidy-win-obj/*.o
```

Upstream config.c emits four discarded-const warnings with this compiler.

Validation: Odin Linux package check passed. C smoke programs linked against
both artifacts, checked `sizeof(Bool)==4`, set all six normalization options,
parsed/repaired/saved a nested-div document and released it. The Windows program
ran under Wine; output matched Linux after removing CR bytes introduced by
Windows default newline and stdout text-mode conversion. Odin Windows build
requires `-windows-sdk-root` and was not validated here.
