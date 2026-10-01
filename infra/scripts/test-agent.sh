#!/bin/sh
set -eu
. "$(dirname "$0")/_agent.sh"

echo "=== bsdOS agent full test ==="
PASS=0; FAIL=0
ok() { echo "  PASS $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL $1"; FAIL=$((FAIL+1)); }

agent_ping    && ok "PING"    || fail "PING"
agent_status  && ok "STATUS"  || fail "STATUS"

echo "--- daemons ---"
agent_hal_start       && ok "HAL_START"       || fail "HAL_START"
agent_broker_start    && ok "BROKER_START"    || fail "BROKER_START"
agent_lifecycle_start && ok "LIFECYCLE_START" || fail "LIFECYCLE_START"

echo "--- builds ---"
agent_build_broker && ok "BUILD_BROKER" || fail "BUILD_BROKER"
agent_build_app    && ok "BUILD_APP"    || fail "BUILD_APP"

echo "--- jails ---"
agent_jail_teardown && ok "JAIL_TEARDOWN" || fail "JAIL_TEARDOWN"
agent_jail_setup    && ok "JAIL_SETUP"    || fail "JAIL_SETUP"
agent_freeze appA   && ok "FREEZE_appA"   || fail "FREEZE_appA"
agent_thaw appA     && ok "THAW_appA"     || fail "THAW_appA"
agent_freeze appB   && ok "FREEZE_appB"   || fail "FREEZE_appB"
agent_thaw appB     && ok "THAW_appB"     || fail "THAW_appB"
agent_jail_teardown && ok "JAIL_TEARDOWN2" || fail "JAIL_TEARDOWN2"

echo "--- demo ---"
agent_run_demo && ok "RUN_DEMO" || fail "RUN_DEMO"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ $FAIL -eq 0 ]
