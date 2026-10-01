#!/bin/sh
# bench-wayland-cpu.sh — F5 damage rect CPU benchmark
# Measures metal-viewer CPU usage over a 30-second idle terminal stream.
# Acceptance: <5% CPU idle (per docs/archive/2026-10-01-monorepo/RELEASE-NOTES-v0.1.1.md claim).
#
# Usage: bench-wayland-cpu.sh [--stream STREAM_KEY] [--duration SECS]
# Output: TSV to stdout + summary to stderr.
# Must run on the Mac host where metal-viewer is running.
#
# Protocol:
#   1. Find metal-viewer PID via pgrep/ps
#   2. Sample ps -p PID -o %cpu,rss,etime every INTERVAL seconds
#   3. After DURATION seconds: print min/avg/max/%cpu + RSS stats
#   4. Exit 0 if avg_cpu < CPU_THRESHOLD, exit 1 otherwise

set -eu

STREAM_KEY="${STREAM_KEY:-appTerminal}"
DURATION="${BENCH_DURATION:-30}"
INTERVAL="${BENCH_INTERVAL:-2}"
CPU_THRESHOLD="${BENCH_CPU_THRESHOLD:-5}"
VIEWER_BIN="metal-viewer"

usage() {
    cat >&2 <<EOF
Usage: $0 [--stream KEY] [--duration SECS] [--interval SECS] [--threshold PCT]

Options:
  --stream KEY       Zenoh stream key to watch (default: appTerminal)
  --duration SECS    Sample window in seconds (default: 30)
  --interval SECS    Polling interval in seconds (default: 2)
  --threshold PCT    Max acceptable avg CPU% (default: 5)

Exit codes:
  0  avg CPU < threshold (pass)
  1  avg CPU >= threshold (fail)
  2  metal-viewer not found
EOF
    exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        --stream)    STREAM_KEY="$2"; shift 2 ;;
        --duration)  DURATION="$2"; shift 2 ;;
        --interval)  INTERVAL="$2"; shift 2 ;;
        --threshold) CPU_THRESHOLD="$2"; shift 2 ;;
        --help|-h)   usage ;;
        *) echo "Unknown option: $1" >&2; usage ;;
    esac
done

# Locate metal-viewer PID
VIEWER_PID=$(pgrep -x "$VIEWER_BIN" 2>/dev/null | head -1 || true)
if [ -z "$VIEWER_PID" ]; then
    echo "ERROR: $VIEWER_BIN not running" >&2
    exit 2
fi

echo "# bench-wayland-cpu: $VIEWER_BIN pid=$VIEWER_PID stream=$STREAM_KEY" >&2
echo "# duration=${DURATION}s interval=${INTERVAL}s threshold=${CPU_THRESHOLD}%" >&2
echo "timestamp_s\tcpu_pct\trss_kb"

SAMPLES=0
SUM_CPU=0
MIN_CPU=999
MAX_CPU=0
T0=$(date +%s)

while true; do
    NOW=$(date +%s)
    ELAPSED=$((NOW - T0))
    [ "$ELAPSED" -ge "$DURATION" ] && break

    # macOS ps: cpu + rss in one call
    # FreeBSD ps: same flags work
    LINE=$(ps -p "$VIEWER_PID" -o "%cpu,rss" 2>/dev/null | tail -1 || true)
    if [ -z "$LINE" ]; then
        echo "ERROR: $VIEWER_BIN (pid=$VIEWER_PID) died during benchmark" >&2
        exit 2
    fi

    CPU=$(echo "$LINE" | awk '{printf "%.1f", $1}')
    RSS=$(echo "$LINE" | awk '{print $2}')

    echo "${ELAPSED}\t${CPU}\t${RSS}"

    # Running stats (integer math via awk)
    SUM_CPU=$(echo "$SUM_CPU $CPU" | awk '{printf "%.1f", $1+$2}')
    MIN_CPU=$(echo "$MIN_CPU $CPU" | awk '{if($2<$1) print $2; else print $1}')
    MAX_CPU=$(echo "$MAX_CPU $CPU" | awk '{if($2>$1) print $2; else print $1}')
    SAMPLES=$((SAMPLES + 1))

    sleep "$INTERVAL"
done

if [ "$SAMPLES" -eq 0 ]; then
    echo "ERROR: no samples collected" >&2
    exit 2
fi

AVG_CPU=$(echo "$SUM_CPU $SAMPLES" | awk '{printf "%.2f", $1/$2}')

echo "" >&2
echo "=== bench-wayland-cpu RESULTS ===" >&2
printf "Samples:   %d\n" "$SAMPLES" >&2
printf "CPU avg:   %.2f%%\n" "$AVG_CPU" >&2
printf "CPU min:   %s%%\n" "$MIN_CPU" >&2
printf "CPU max:   %s%%\n" "$MAX_CPU" >&2
printf "Threshold: %s%%\n" "$CPU_THRESHOLD" >&2

PASS=$(echo "$AVG_CPU $CPU_THRESHOLD" | awk '{if($1<$2) print "PASS"; else print "FAIL"}')
echo "Result:    $PASS" >&2

if [ "$PASS" = "PASS" ]; then
    exit 0
else
    exit 1
fi
