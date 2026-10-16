#!/usr/bin/env bash
set -euo pipefail

# Resolve the repository regardless of the caller's working directory.
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.."
if [[ -n "$(git status --porcelain --untracked-files=all)" ]]; then
    printf 'Working tree must match HEAD (no staged, unstaged, or untracked files).\n' >&2
    git status --short >&2
    exit 1
fi
if ! task --status build; then
    printf 'Server build is missing or stale. Run: task build\n' >&2
    exit 1
fi

# Server CLI flags are forwarded. Override benchmark settings via environment.
port=8081
for arg in "$@"; do
    case "$arg" in -port=*) port=${arg#-port=} ;; esac
done
url=${BENCH_URL:-http://127.0.0.1:$port/}
log=${BENCH_LOG:-/tmp/booru-bench.log}
command -v oha >/dev/null
sudo -v

# Refuse an occupied port so we cannot accidentally benchmark another server.
if ss -H -ltn "sport = :$port" | grep -q .; then
    printf 'Port %s is already occupied. Choose another -port=.\n' "$port" >&2
    exit 1
fi
if sudo test -e /sys/fs/cgroup/booru-bench; then
    printf 'booru-bench cgroup already exists; refusing to interfere.\n' >&2
    exit 1
fi

sudo bash -s -- "$(id -u)" "$(id -g)" "-port=$port" "$@" >"$log" 2>&1 <<'EOF' &
set -euo pipefail
cg=/sys/fs/cgroup/booru-bench
mkdir "$cg"
trap 'rmdir "$cg"' EXIT

echo 2,3 > "$cg/cpuset.cpus"
echo 2,3 > "$cg/cpuset.cpus.exclusive"
echo isolated > "$cg/cpuset.cpus.partition"
state=$(< "$cg/cpuset.cpus.partition")
if [[ "$state" != isolated ]]; then
    printf 'Partition setup failed: %s\n' "$state" >&2
    exit 1
fi

echo 536870912 > "$cg/memory.max"
echo 0 > "$cg/memory.swap.max"

uid=$1
gid=$2
shift 2
(
    echo "$BASHPID" > "$cg/cgroup.procs"
    exec setpriv --reuid="$uid" --regid="$gid" --init-groups \
        taskset -c 2 ./bin/booru "$@"
)
EOF
server=$!
cleanup() {
    # Kill every server task, allowing the server launcher to remove its cgroup.
    sudo sh -c 'if [ -e /sys/fs/cgroup/booru-bench/cgroup.kill ]; then echo 1 > /sys/fs/cgroup/booru-bench/cgroup.kill; fi' || true
    wait "$server" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

wait_for_server() {
    for ((i=0; i<150; i++)); do
        kill -0 "$server" 2>/dev/null || return 1
        if curl --silent --output /dev/null --max-time 1 "$url"; then
            return 0
        fi
        sleep 0.2
    done
    return 1
}
if ! wait_for_server; then
    printf 'Server failed to become ready; see %s\n' "$log" >&2
    tail -n 30 "$log" >&2
    exit 1
fi

printf 'Server log: %s\nBenchmark: %s\n' "$log" "$url" >&2
oha -z "${BENCH_DURATION:-30s}" -c "${BENCH_CONCURRENCY:-32}" "$url"
