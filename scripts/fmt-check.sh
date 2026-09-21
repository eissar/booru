#!/usr/bin/env bash
# Fail if any Odin source would be rewritten by `odin fmt`.
# `odin fmt` has no --check flag, so format a scratch copy and diff.
set -euo pipefail
cd "$(dirname "$0")/.."

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

status=0
src_odin() {
    find src -name '*.odin' -not -path '*/testdata/*'
}

while IFS= read -r file; do
    mkdir -p "$scratch/$(dirname "$file")"
    cp "$file" "$scratch/$file"
done < <(src_odin)

odin fmt "$scratch/src" >/dev/null 2>&1 || true

while IFS= read -r file; do
    if ! cmp -s "$file" "$scratch/$file"; then
        echo "not formatted: $file"
        status=1
    fi
done < <(src_odin)

if [ "$status" -ne 0 ]; then
    echo
    echo "run 'task fmt' to fix"
fi

exit "$status"