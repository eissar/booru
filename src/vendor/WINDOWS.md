# Windows x64 libraries

The `windows-amd64/` directories contain Windows x64 COFF libraries. Odin
bindings select these on Windows and retain system-library imports elsewhere.
The binaries are x64 only, not Windows i386 builds.

- **HTML Tidy 5.8.0:** locally cross-compiled static archive using Clang 19's
  `x86_64-pc-windows-msvc` target and xwin, with static MSVC CRT. No Tidy DLL is needed. See `tidy/README.md`
  for source provenance, build commands, ABI notes, and smoke-test scope.
- **SQLite 3.54.1:** DLL plus generated import library. Public domain; see
  <https://www.sqlite.org/copyright.html>. `test/tools/windows.sh` copies the
  DLL beside the test executable. Applications must do the same.
- **libwebp 1.6.0:** upstream static library, including SharpYUV objects. No
  WebP DLL is needed. License and patent grant are alongside the library.
- **dav1d 1.5.4:** locally cross-compiled static library, matching the version
  documented in `dav1d.odin`. No dav1d DLL is needed. BSD license is alongside
  the library. Built with x86 assembly enabled and both 8/16-bit decoding.

Verify the vendored binary files from the repository root with:

```sh
sha256sum -c src/vendor/windows-amd64.sha256
```

## Download provenance

URLs and SHA-256 of the downloaded archives (recorded locally, not an
independent publisher-signature verification):

| Dependency | URL | SHA-256 |
|---|---|---|
| HTML Tidy source | https://github.com/htacg/tidy-html5/archive/refs/tags/5.8.0.tar.gz | `59c86d5b2e452f63c5cdb29c866a12a4c55b1741d7025cf2f3ce0cde99b0660e` |
| SQLite | https://www.sqlite.org/2026/sqlite-dll-win-x64-3540100.zip | `f436f53ad8f965af43f3817b42c99c0689e6787f6b7ace208fe38dab7ffc4971` |
| WebP | https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-1.6.0-windows-x64.zip | `48886f506b21f62e4661f0f4cbfca19800897c385128e8902542d29a950c93f1` |
| dav1d source | https://code.videolan.org/videolan/dav1d/-/archive/1.5.4/dav1d-1.5.4.tar.gz | `a1d5b63d2d38ec9bd03acf643caa51fa22edd1e89c5a109c4807717216bbec07` |

WebP COPYING and PATENTS were fetched from the upstream `v1.6.0` tag; dav1d
COPYING comes from its source archive. SQLite's upstream DLL archive has no
license file.

## Updating SQLite / WebP

Extract `sqlite3.dll` and `sqlite3.def` from the SQLite archive, then generate
its import library (Zig 0.17.0 was used):

```sh
zig dlltool -m i386:x86-64 \
  -d src/vendor/sqlite/windows-amd64/sqlite3.def \
  -l src/vendor/sqlite/windows-amd64/sqlite3.lib -D sqlite3.dll
```

For WebP, extract `lib/libwebp.lib` from the Windows x64 archive. The tested
library's object directives use `LIBCMT` (static MSVC CRT). Recheck the Odin
struct layouts and the API/ABI version numbers before upgrading either codec.

## Rebuilding dav1d

Build tools used: Clang/LLVM 19.1.7, Meson 1.12.1, Ninja 1.13.2, NASM 2.16.03,
and xwin's Windows SDK/MSVC CRT headers and libraries. Zig's `lld-link` wrapper
was on PATH. Meson/Ninja/NASM are only needed to rebuild, not to run tests.

Extract the dav1d source archive. Create `cross.ini`, replacing `/path/to/xwin`
with an absolute path to the xwin splat output:

```ini
[binaries]
c = ['clang-19', '--target=x86_64-pc-windows-msvc', '-isystem', '/path/to/xwin/crt/include', '-isystem', '/path/to/xwin/sdk/include/ucrt', '-isystem', '/path/to/xwin/sdk/include/shared', '-isystem', '/path/to/xwin/sdk/include/um']
ar = 'llvm-ar-19'
c_ld = 'lld'
strip = 'llvm-strip-19'

[host_machine]
system = 'windows'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'

[properties]
needs_exe_wrapper = true

[built-in options]
c_link_args = ['-L/path/to/xwin/crt/lib/x86_64', '-L/path/to/xwin/sdk/lib/um/x86_64', '-L/path/to/xwin/sdk/lib/ucrt/x86_64']
b_vscrt = 'mt'
```

Then, from the directory containing the source tree:

```sh
meson setup dav1d-build dav1d-1.5.4 --cross-file cross.ini \
  --buildtype release --default-library static \
  -Denable_tools=false -Denable_tests=false -Denable_examples=false
ninja -C dav1d-build
cp dav1d-build/src/libdav1d.a /path/to/booru/src/vendor/dav1d/windows-amd64/dav1d.lib
```

The `.a` is an archive of Windows COFF objects, not Linux ELF. Renaming it to
`.lib` lets the Odin Windows binding use it directly. It uses the static CRT
(`-fms-runtime-lib=static`), matching the WebP archive.

## Odin's own STB libraries

These belong to the Odin installation, not this project's vendor directories.
The local setup extracted `vendor/stb/lib/*.lib` from the official
`odin-windows-amd64-dev-2026-10.zip`, downloaded using:

```sh
gh release download dev-2026-10 -R odin-lang/Odin \
  -p 'odin-windows-amd64*.zip'
```

Use a release matching your Odin version. Keep the existing Linux `.a` files.
The installed compiler here is `dev-2026-10-nightly:84bc3fc`; the archive is the
monthly release, not that exact nightly revision.

## Validation and remaining work

Run `test/tools/windows.sh`; its header documents SDK setup and the workaround
for Odin's recursive traversal of xwin's cyclic directory symlinks.

The full test executable links and starts under Wine 10.0 with these libraries.
Its imports include sqlite3.dll but no dav1d/WebP DLL or VC runtime DLL. The
media package's two tests pass under Wine, but they do not establish complete
codec ABI coverage. After rebuilding Tidy with the MSVC static CRT, validation with
`timeout --kill-after=10s 120s bash test/tools/windows.sh` linked successfully
and completed all 45 tests, exiting 1 (not a timeout). Three tests failed:
`test.import_browse_delete_replay` (GET /gallery returned 0 instead of 200),
`thumbnail.generate_missing_fixture_thumbnails` (missing-source reporting), and
`thumbnail.stream_webp_socket_batches` (external command status). See
`tidy/README.md` for the Tidy rebuild commands. Successful linking is not a
passing Windows suite.
