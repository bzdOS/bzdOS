#!/bin/sh
# Запускается внутри FreeBSD гостя как root
# Тест lifecycle daemon: FREEZE/STATUS/THAW/HIBERNATE
set -eu
SOCK=/var/run/bsdos-lifecycle.sock
PASS=0; FAIL=0

ok()   { echo "  PASS $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL $1: $2"; FAIL=$((FAIL+1)); }

lc() {
    # break-after-response: daemon закрывает соединение сразу после ответа.
    # Поэтому nc получает ответ + EOF и немедленно выходит.
    printf "%s\n" "$1" | nc -w15 -U "$SOCK" 2>/dev/null || echo "-ERR timeout"
}

# Daemon checks
pgrep -x bsdos-lifecycled >/dev/null && ok "daemon running" || fail "daemon" "not running"
test -S "$SOCK" && ok "socket exists" || fail "socket" "missing"

r=$(lc "MEM_STATUS")
echo "  MEM_STATUS → $r"
case "$r" in *free*) ok "MEM_STATUS" ;; *) fail "MEM_STATUS" "$r" ;; esac

# Jail lifecycle tests
/opt/proto/jailmgr.sh setup-all >/dev/null 2>&1 || true
sleep 1

r=$(lc "FREEZE appA")
echo "  FREEZE appA → $r"
case "$r" in *OK*) ok "FREEZE" ;; *) fail "FREEZE" "$r" ;; esac

r=$(lc "STATUS appA")
echo "  STATUS appA → $r"
case "$r" in *Frozen*) ok "STATE=Frozen" ;; *) fail "STATE=Frozen" "$r" ;; esac

r=$(lc "THAW appA")
echo "  THAW appA → $r"
case "$r" in *OK*) ok "THAW" ;; *) fail "THAW" "$r" ;; esac

r=$(lc "STATUS appA")
echo "  STATUS appA → $r"
case "$r" in *Running*) ok "STATE=Running" ;; *) fail "STATE=Running" "$r" ;; esac

r=$(lc "SET_PRIORITY appB 200")
echo "  SET_PRIORITY → $r"
case "$r" in *priority*) ok "SET_PRIORITY" ;; *) fail "SET_PRIORITY" "$r" ;; esac

/opt/proto/jailmgr.sh teardown-all >/dev/null 2>&1 || true

echo ""
echo "=== lifecycle: $PASS passed, $FAIL failed ==="
[ $FAIL -eq 0 ]
