#!/usr/bin/env bash
# Cross-build Odin tests and run them with Wine (Linux host, Windows x64).
# Usage: test/tools/windows.sh [extra Odin build flags]
# Overrides: WIN_SDK_ROOT (default ~/.xwin), WIN_TEST_PKG (default test),
#            WINEPREFIX (default ~/.wine-booru-test).
# Reuses .test-data/curl/curl.exe; downloads the official Windows binary
# there on first use (requires host curl, unzip, and sha256sum).
#
# Setup: install Wine, Odin, and Zig; download the x64 SDK/CRT using xwin:
#   xwin --accept-license --arch x86_64 --cache-dir "$HOME/.xwin-cache" \
#     splat --output "$HOME/.xwin"
# xwin is needed only for setup. Keep cache and output on the same filesystem.
# Odin invokes lld-link by name; put a wrapper on PATH if Zig provides LLD:
#   #!/bin/sh
#   exec zig lld-link "$@"
#
# Why a separate SDK view?
# xwin creates sdk/{include,lib}/<version> -> . symlinks. Pointing Odin's
# -windows-sdk-root directly at that tree made its recursive SDK scan spend
# over 90 seconds in read_directory/realpath before launching LLD. A view
# containing only architecture-specific library directories avoids those
# cycles and unnecessary header scanning, without modifying xwin's files.
# The directory benchmark then built AND linked in ~2.7 s; linking alone
# took ~27 ms. These are local measurements, not performance guarantees.
#
# Windows sqlite3, dav1d, and libwebp libraries live under src/vendor/.
# Odin's vendor:stb Windows libraries must be installed separately (extract
# vendor/stb/lib/*.lib from the matching official Odin Windows release).
# See src/vendor/WINDOWS.md for versions, provenance, and build instructions.
# Wine checks execution, not minimum-Windows-version compatibility; inspect
# imports separately and test on real Windows before claiming support.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."

missing=()
for tool in odin lld-link wine wineboot wineserver; do
  command -v "$tool" >/dev/null 2>&1 || missing+=("command: $tool")
done
curl_dir="$PWD/.test-data/curl"
if [[ ! -s "$curl_dir/curl.exe" ]]; then
  for tool in curl unzip sha256sum; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("command: $tool (curl.exe setup)")
  done
fi
sdk="${WIN_SDK_ROOT:-$HOME/.xwin}"
for dir in crt/lib/x86_64 sdk/lib/um/x86_64 sdk/lib/ucrt/x86_64; do
  [[ -d "$sdk/$dir" ]] || missing+=("directory: $sdk/$dir")
done
for lib in crt/lib/x86_64/libcmt.lib sdk/lib/um/x86_64/kernel32.lib sdk/lib/ucrt/x86_64/libucrt.lib; do
  [[ -r "$sdk/$lib" ]] || missing+=("library: $sdk/$lib")
done
for lib in \
  src/vendor/sqlite/windows-amd64/sqlite3.lib \
  src/vendor/sqlite/windows-amd64/sqlite3.dll \
  src/vendor/libwebp/windows-amd64/libwebp.lib \
  src/vendor/dav1d/windows-amd64/dav1d.lib; do
  [[ -r "$lib" ]] || missing+=("vendored library: $lib (see src/vendor/WINDOWS.md)")
done
if (( ${#missing[@]} )); then
  printf 'Missing Windows build requirements:\n' >&2
  printf '  %s\n' "${missing[@]}" >&2
  exit 2
fi
sdk="$(cd "$sdk" && pwd -P)"

# curl.exe is self-contained apart from Windows system DLLs. Install it last
# so an interrupted download/extraction is retried on the next invocation.
if [[ ! -s "$curl_dir/curl.exe" ]]; then
  (
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    release=curl-8.23.0_1-win64-mingw
    echo "Downloading $release..."
    curl --fail --location --silent --show-error \
      "https://curl.se/windows/dl-8.23.0_1/$release.zip" -o "$tmp/curl.zip"
    echo "752ff19c45be64af5b5f8d5222dce64e0f7b03d740a7362a4055c220fa9637c6  $tmp/curl.zip" | sha256sum -c -
    unzip -q "$tmp/curl.zip" "$release/bin/curl.exe" \
      "$release/bin/curl-ca-bundle.crt" "$release/COPYING.txt" -d "$tmp"
    mkdir -p "$curl_dir"
    cp "$tmp/$release/COPYING.txt" "$tmp/$release/bin/curl-ca-bundle.crt" "$curl_dir/"
    mv "$tmp/$release/bin/curl.exe" "$curl_dir/curl.exe"
  )
fi
# Make the unchanged test command "curl" resolve to curl.exe under Wine.
curl_windows="Z:${curl_dir//\//\\}"
export WINEPATH="$curl_windows${WINEPATH:+;$WINEPATH}"

# Only point at the final library directories, never the versioned parents.
# Their case-alias file symlinks are safe; the directory cycles are excluded.
view="$PWD/bin/win/sdk-root"
mkdir -p "$view"
for kind in crt um ucrt; do
  case "$kind" in
    crt) source="$sdk/crt/lib/x86_64" ;;
    *) source="$sdk/sdk/lib/$kind/x86_64" ;;
  esac
  if [[ -e "$view/$kind" && ! -L "$view/$kind" ]]; then
    echo "error: refusing to replace non-symlink $view/$kind" >&2
    exit 2
  fi
  ln -sfn "$source" "$view/$kind"
done

# Odin treats this string as linker arguments. Quote paths for spaces.
link_flags="/libpath:\"$view/crt\" /libpath:\"$view/um\" /libpath:\"$view/ucrt\""
odin build "${WIN_TEST_PKG:-test}" \
  -target:windows_amd64 -linker:lld \
  -windows-sdk-root:"$view" \
  -build-mode:test -all-packages \
  -extra-linker-flags:"$link_flags" \
  -out:bin/win/tests.exe "$@"

# SQLite uses a DLL; WebP and dav1d are linked statically.
cp src/vendor/sqlite/windows-amd64/sqlite3.dll bin/win/

# A home-directory prefix also avoids Wine's refusal to initialize a prefix
# inside a repository owned by another user. Initialization happens once.
export WINEPREFIX="${WINEPREFIX:-$HOME/.wine-booru-test}"
export WINEARCH=win64
export WINEDEBUG="${WINEDEBUG:--all}"
export WINEDLLOVERRIDES="${WINEDLLOVERRIDES:-mscoree,mshtml=}"
if [[ "$WINEPREFIX" != /* ]]; then
  echo 'error: WINEPREFIX must be an absolute path' >&2
  exit 2
fi
if [[ ! -f "$WINEPREFIX/system.reg" ]]; then
  wineboot --init
  wineserver --wait
fi
exec wine "$PWD/bin/win/tests.exe"
