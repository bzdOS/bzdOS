#!/bin/sh
# vm-tune-scheduler.sh — FreeBSD ULE scheduler tuning for mobile devices
#
# Usage:
#   ./vm-tune-scheduler.sh [MODE]
#   ./vm-tune-scheduler.sh performance   # Hz=1000, interactive
#   ./vm-tune-scheduler.sh normal        # Hz=100, balanced (default)
#   ./vm-tune-scheduler.sh powersave     # Hz=15, battery mode
#
# Or via environment:
#   POWER_MODE=normal ./vm-tune-scheduler.sh
#
# Via Makefile:
#   make vm-tune-scheduler               # default: normal
#   make vm-tune-scheduler POWER_MODE=powersave

set -eu
. "$(dirname "$0")/_ssh.sh"

MODE="${1:-${POWER_MODE:-normal}}"

# Validate mode
case "$MODE" in
    performance|normal|powersave)
        ;;
    *)
        echo "Usage: $0 {performance|normal|powersave}" >&2
        echo "" >&2
        echo "Modes:" >&2
        echo "  performance  — Hz=1000 (interactive, screen-on)" >&2
        echo "  normal       — Hz=100 (balanced, recommended idle)" >&2
        echo "  powersave    — Hz=15 (battery mode, screen-off)" >&2
        exit 1
        ;;
esac

# Configure sysctl for each mode
case "$MODE" in
    performance)
        # Screen on, active use: maximize responsiveness
        HZ=1000
        PREEMPT=224
        AFFINITY=1
        DESC="interactive (screen on, active)"
        ;;
    normal)
        # Default mobile mode: balance power and responsiveness
        HZ=100
        PREEMPT=224
        AFFINITY=1
        DESC="balanced (idle, normal use)"
        ;;
    powersave)
        # Deep sleep: minimize CPU wakeups, accept higher latency
        HZ=15
        PREEMPT=128
        AFFINITY=0
        DESC="power-saving (screen off, battery critical)"
        ;;
esac

# Apply sysctl on FreeBSD guest as root
echo "[sched] Tuning to mode=$MODE ($DESC)..."
ssh_root "sysctl kern.hz=$HZ kern.sched.preempt_thresh=$PREEMPT kern.sched.affinity=$AFFINITY"

echo "[sched] ✓ Scheduler tuned:"
echo "  kern.hz=$HZ (interrupts/sec)"
echo "  kern.sched.preempt_thresh=$PREEMPT (priority boost)"
echo "  kern.sched.affinity=$AFFINITY (cache locality)"
echo ""
echo "[sched] Mode: $MODE ($DESC)"
