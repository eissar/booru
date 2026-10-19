#!/usr/bin/env bash
set -euo pipefail

# Resolve the repository regardless of the caller's working directory.
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.."
task_bin=$(command -v task) || { printf "task not found in PATH\n" >&2; exit 1; }

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

sudo env "PATH=$PATH" "HOME=$HOME" bash -s -- "$(id -u)" "$(id -g)" "$task_bin" "-port=$port" "$@" >"$log" 2>&1 <<'EOF' &
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

uid=$1
gid=$2
task_bin=$3
shift 3
(
    echo "$BASHPID" > "$cg/cgroup.procs"
    exec setpriv --reuid="$uid" --regid="$gid" --init-groups \
        taskset -c 2 "$task_bin" run -- -o:speed -- "$@"
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
    for ((i=0; i<600; i++)); do
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
