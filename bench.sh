#!/usr/bin/env bash
set -euo pipefail

out="${BENCH_JSON:-$PWD/bin/bench.json}"
tmp="$(mktemp "${TMPDIR:-/tmp}/booru-bench.XXXXXX.json")"
trap 'rm -f "$tmp"' EXIT

systemd-run --user \
  --unit=booru-memory-bench \
  --collect --pipe --wait \
  --property=MemoryAccounting=yes \
  --working-directory="$PWD" \
  -- "$PWD/bin/bench" >"$tmp"

# Preserve Odin's JSON. Convert only the displayed memory values to MiB.
python3 - "$tmp" "$out" <<'PY'
import json
from pathlib import Path
import sys

PHASES = ("baseline", "touched", "freed")
MIB = 1024 * 1024
ROWS = {
    "Cgroup current": ("cgroup", "memory.current"),
    "Cgroup peak": ("cgroup", "memory.peak"),
    "  Anonymous": ("cgroup", "memory.stat", "anon"),
    "  File cache": ("cgroup", "memory.stat", "file"),
    "  Kernel": ("cgroup", "memory.stat", "kernel"),
    "  Socket": ("cgroup", "memory.stat", "sock"),
    "Process RSS": ("process", "smaps_rollup", "Rss"),
    "Process PSS": ("process", "smaps_rollup", "Pss"),
    "Process RSS peak": ("process", "status", "VmHWM"),
}


def memory_value(snapshot, path):
    value = snapshot
    for key in path:
        value = value.get(key) if isinstance(value, dict) else None
    if value is None:
        return None
    if value.endswith(" kB"):
        return int(value[:-3].strip()) * 1024
    return int(value)


try:
    report = json.loads(Path(sys.argv[1]).read_text())
    buffer_bytes = int(report["buffer_bytes"])
    if buffer_bytes <= 0:
        raise ValueError("buffer_bytes must be positive")
    snapshots = [report["phases"][phase] for phase in PHASES]
    columns = [[memory_value(s, path) for s in snapshots] for path in ROWS.values()]
except (ValueError, KeyError, TypeError, AttributeError, OSError) as error:
    sys.exit(f"Invalid benchmark output: {error}\nRebuild with: task --force build:bench")

out = Path(sys.argv[2])
out.parent.mkdir(parents=True, exist_ok=True)
out.write_bytes(Path(sys.argv[1]).read_bytes())

headers = ("Baseline", f"+{buffer_bytes / MIB:g} touched", "Freed")
width = max(12, *(len(header) for header in headers))
print("Memory comparison (MiB)")
print(f"{'Metric':20}  " + "  ".join(f"{header:>{width}}" for header in headers))
print("-" * (20 + (width + 2) * 3))
for label, values in zip(ROWS, columns):
    cells = [f"{value / MIB:.2f}" if value is not None else "-" for value in values]
    print(f"{label:20}  " + "  ".join(f"{cell:>{width}}" for cell in cells))
print("\nCgroup includes charged kernel memory; table rows overlap, do not sum.")
print("Peak includes startup. Probes add overhead; freeing may not release pages.")
if not report.get('cgroup_path') or any('memory.current' not in s.get('cgroup', {}) for s in snapshots):
    print("warning: cgroup counters unavailable; missing values shown as '-'.", file=sys.stderr)
print(f"JSON saved to: {out}")
PY
