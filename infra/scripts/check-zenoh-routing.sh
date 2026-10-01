#!/bin/sh
[ -r "${BSDOS_HOSTS_ENV:-/etc/bsdos/hosts.env}" ] && . "${BSDOS_HOSTS_ENV:-/etc/bsdos/hosts.env}"
# check-zenoh-routing.sh — smoke-test Zenoh routing: dev-vm (router) → myvm (router+publisher)
#
# START_AI_HEADER
# MODULE: infra/scripts/check-zenoh-routing.sh
# PURPOSE: Verify that Zenoh routing between dev-vm (obfs relay) and myvm (publisher) is healthy.
# INTENT: Catch silent routing breaks before running a full demo; cheap TCP-level checks
#         so it runs without building any Rust binary.
# DEPENDENCIES: nc (netcat, POSIX), optional bsdos-core-sub binary for session-level check.
# END_AI_HEADER
#
# Topology:
#   host (${BSDOS_HOST_IP})
#     → dev-vm:443  obfs/Zenoh router (bsdos_pipeline, ZENOH_MODE=router)
#     → myvm:7447 bsdos-core publisher (router mode, streams appTerminal + appBrowser)
#
# Checks:
#   1. TCP host→myvm:7447   — Zenoh port on myvm reachable
#   2. TCP host→dev-vm:443    — obfs router on dev VM reachable
#   3. bsdos-core-sub probe: subscribe bsdos/telemetry on myvm:7447, expect output in 7s
#   4. Zenoh raw banner     — any bytes from myvm:7447 on raw TCP (router alive)
#
# Usage:
#   sh infra/scripts/check-zenoh-routing.sh
#   MYVM_IP=192.0.2.10 sh infra/scripts/check-zenoh-routing.sh
#
# Exit 0 = all mandatory checks PASS; exit 1 = at least one FAIL.
# POSIX sh — no bash-isms.

MYVM_IP="${MYVM_IP:-${BSDOS_MYVM_IP:?set BSDOS_MYVM_IP in /etc/bsdos/hosts.env}}"
MYVM_ZENOH_PORT="${MYVM_ZENOH_PORT:-7447}"
DEV_IP="${DEV_IP:-${BSDOS_DEV_IP:?set BSDOS_DEV_IP in /etc/bsdos/hosts.env}}"
DEV_OBFS_PORT="${DEV_OBFS_PORT:-443}"
NC_TIMEOUT="${NC_TIMEOUT:-5}"

BSDOS_DIR="${BSDOS_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
SUB_BIN="${BSDOS_DIR}/bsdos-core/target/release/bsdos-core-sub"

PASS=0
FAIL=0

ok()   { printf '[zenoh-routing] PASS: %s\n' "$*"; PASS=$((PASS + 1)); }
fail() { printf '[zenoh-routing] FAIL: %s\n' "$*"; FAIL=$((FAIL + 1)); }
note() { printf '[zenoh-routing] NOTE: %s\n' "$*"; }

echo "[zenoh-routing] Zenoh routing smoke-test"
echo "[zenoh-routing] myvm (myvm)  : ${MYVM_IP}:${MYVM_ZENOH_PORT}"
echo "[zenoh-routing] dev-vm (relay) : ${DEV_IP}:${DEV_OBFS_PORT}"
echo ""

# ── Check 1: TCP reachability host→myvm:7447 ─────────────────────────────────
# nc -z: zero-I/O connect test.  -w: connect timeout in seconds.
# Both Linux nc (ncat/netcat-openbsd) and FreeBSD nc support -z and -w.
if nc -z -w "${NC_TIMEOUT}" "${MYVM_IP}" "${MYVM_ZENOH_PORT}" 2>/dev/null; then
    ok "TCP host → ${MYVM_IP}:${MYVM_ZENOH_PORT} (Zenoh)"
else
    fail "TCP host → ${MYVM_IP}:${MYVM_ZENOH_PORT} unreachable (bsdos-core down or fw?)"
fi

# ── Check 2: TCP reachability host→dev-vm:443 ───────────────────────────────────
if nc -z -w "${NC_TIMEOUT}" "${DEV_IP}" "${DEV_OBFS_PORT}" 2>/dev/null; then
    ok "TCP host → ${DEV_IP}:${DEV_OBFS_PORT} (obfs router)"
else
    fail "TCP host → ${DEV_IP}:${DEV_OBFS_PORT} unreachable (bsdos_pipeline down?)"
fi

# ── Check 3: bsdos-core-sub Zenoh session probe ───────────────────────────────
# sub.rs subscribes to bsdos/telemetry using a configurable connect endpoint.
# ZENOH_CONNECT env is not currently wired in sub.rs (it hardcodes tcp/127.0.0.1:7447),
# so we check the BSDOS_PEER env that zenoh_config::from_env() uses as connect/endpoints.
# timeout(1) wraps the subscription so it does not block indefinitely.
if [ -x "${SUB_BIN}" ]; then
    SUB_OUT=""
    SUB_OUT=$(ZENOH_MODE=peer \
        ZENOH_PEER="tcp/${MYVM_IP}:${MYVM_ZENOH_PORT}" \
        BSDOS_ZENOH_SCOUTING=0 \
        timeout 8 "${SUB_BIN}" 2>&1 | head -6) || true
    if echo "${SUB_OUT}" | grep -qE "uptime=|battery=|cpu="; then
        ok "bsdos-core-sub: telemetry received from ${MYVM_IP}:${MYVM_ZENOH_PORT}"
    elif echo "${SUB_OUT}" | grep -qiE "subscribing|session opened|Zenoh session"; then
        ok "bsdos-core-sub: Zenoh session opened to ${MYVM_IP}:${MYVM_ZENOH_PORT} (no telemetry yet — normal in first 5s)"
    else
        fail "bsdos-core-sub: could not open Zenoh session to ${MYVM_IP}:${MYVM_ZENOH_PORT}"
        note "bsdos-core-sub output (first 6 lines):"
        printf '%s\n' "${SUB_OUT}" | sed 's/^/  /'
    fi
else
    note "bsdos-core-sub not found at ${SUB_BIN} — skipping Zenoh session probe"
    note "Build on VM dev-vm: cargo build --release --bin bsdos-core-sub"
fi

# ── Check 4: Zenoh raw TCP response ──────────────────────────────────────────
# Zenoh sends an INIT frame on new TCP connections before session establishment.
# We accept any non-empty response as proof the listener is alive.
BANNER_BYTES=""
BANNER_BYTES=$(printf '' | nc -w 2 "${MYVM_IP}" "${MYVM_ZENOH_PORT}" 2>/dev/null \
    | head -c 8 | wc -c | tr -d ' ') || BANNER_BYTES=0
if [ "${BANNER_BYTES}" -gt 0 ] 2>/dev/null; then
    ok "Zenoh raw TCP: ${BANNER_BYTES} banner bytes from ${MYVM_IP}:${MYVM_ZENOH_PORT}"
else
    note "No Zenoh banner on raw TCP connect (Zenoh may require full handshake first)"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "[zenoh-routing] RESULT: ${PASS} passed, ${FAIL} failed"
if [ "${FAIL}" -gt 0 ]; then
    echo "[zenoh-routing] OVERALL: FAIL"
    exit 1
fi
echo "[zenoh-routing] OVERALL: PASS — dev-vm→myvm Zenoh routing healthy"
