#!/bin/sh
set -eu
. "$(dirname "$0")/_agent.sh"
OP="${1:-status}"
case "$OP" in
  demo)      agent_hal_start; agent_broker_start; sleep 1; agent_jail_setup; echo "demo started via agent" ;;
  build)     agent_build_broker; agent_build_app; echo "builds started (background)" ;;
  jails)     agent_jail_setup; echo "jails ready" ;;
  start)     agent_hal_start; agent_broker_start; agent_lifecycle_start; echo "daemons started" ;;
  teardown)  agent_jail_teardown; echo "jails torn down" ;;
  ping)      agent_ping ;;
  *) echo "usage: $0 demo|build|jails|start|teardown|ping" ;;
esac
