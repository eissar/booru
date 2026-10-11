#!/usr/bin/env bash
# Run outside the server's cgroup. Requires curl and jq.
# Usage: ./bench/requests.sh SERVER_PID URL [REQUEST_COUNT]
# Outputs one JSON report to stdout; writes no result files.
set -euo pipefail

pid=${1:?Usage: requests.sh SERVER_PID URL [REQUEST_COUNT]}
url=${2:?Usage: requests.sh SERVER_PID URL [REQUEST_COUNT]}
count=${3:-10}

membership=$(awk -F: '$1 == "0" { print $3 }' "/proc/$pid/cgroup")
[[ -n "$membership" ]] || { echo 'Server has no cgroup v2 membership' >&2; exit 1; }
cgroup="/sys/fs/cgroup$membership"

fields() {
    jq -Rn --arg separator "$2" '
        reduce inputs as $line ({};
            ($line | index($separator)) as $i |
            if $i == null then . else
                .[($line[:$i] | gsub("^\\s+|\\s+$"; ""))] =
                    ($line[$i + 1:] | gsub("^\\s+|\\s+$"; ""))
            end
        )
    ' < "$1"
}

snapshot() {
    local phase=$1 timing=${2:-null} file value
    local counters='{}' process='{}'

    for file in memory.current memory.peak memory.stat memory.events \
                memory.events.local memory.swap.current memory.swap.peak \
                memory.swap.events memory.max memory.high memory.low memory.min; do
        [[ -r "$cgroup/$file" ]] || continue
        case "$file" in
            memory.stat|*events*) value=$(fields "$cgroup/$file" ' ') ;;
            *) value=$(jq -Rs 'gsub("^\\s+|\\s+$"; "")' < "$cgroup/$file") ;;
        esac
        counters=$(jq -cn --argjson data "$counters" --arg key "$file" \
            --argjson value "$value" '$data + {($key): $value}')
    done

    for file in status smaps_rollup; do
        value=$(fields "/proc/$pid/$file" ':')
        process=$(jq -cn --argjson data "$process" --arg key "$file" \
            --argjson value "$value" '$data + {($key): $value}')
    done

    jq -cn --arg phase "$phase" --arg pid "$pid" --arg cgroup_path "$cgroup" \
        --argjson cgroup "$counters" --argjson process "$process" \
        --argjson timing "$timing" \
        '{phase: $phase, pid: $pid, cgroup_path: $cgroup_path,
          timing: $timing, cgroup: $cgroup, process: $process}'
}

# Wait for server readiness separately: this baseline sends no warm-up request.
snapshots=$(snapshot baseline)
for ((request = 1; request <= count; request++)); do
    timing=$(curl --fail --silent --show-error --output /dev/null \
        --write-out '{"total_seconds":"%{time_total}","first_byte_seconds":"%{time_starttransfer}","http_status":"%{http_code}"}' \
        "$url")
    snapshots+=$'\n'$(snapshot "request-$request" "$timing")
done

printf '%s\n' "$snapshots" | jq -s '
    . as $snapshots |
    [ .[] | select(.timing != null) | (.timing.total_seconds | tonumber) ] as $times |
    {
        speed: {
            requests: ($times | length),
            mean_seconds: (if ($times | length) > 0 then ($times | add / length) else null end),
            min_seconds: ($times | min),
            max_seconds: ($times | max)
        },
        snapshots: $snapshots
    }
'
