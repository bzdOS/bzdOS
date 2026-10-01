#!/bin/sh
#
# apply-network-policy.sh
# Host-side control-plane script: parses proto/network-policy.json and applies PF rules to guest
#
# Usage:
#   SSH_KEY=./bsdos-key VM_SSH_PORT=2222 POLICY_JSON=./proto/network-policy.json \
#     ./apply-network-policy.sh
#
# Algorithm (Phase 1 skeleton):
#   1. Verify JSON syntax with jq (host-side)
#   2. Extract jails array: name, ip4, allowed_ports, pf_rules_enabled
#   3. Generate PF rules template:
#      - For each jail with pf_rules_enabled=true:
#        * Create pfctl table: <appA_nets> = {10.0.1.10}
#        * Create rules: block out from <appA_nets> except allowed_ports
#   4. Transfer JSON to guest: /tmp/network-policy.json
#   5. SSH to guest + run: /opt/proto-src/scripts/apply-network-policy-guest.sh
#   6. Guest script:
#      * jq parse /tmp/network-policy.json
#      * printf render /opt/proto/pf.conf with inet rules
#      * pfctl -f /opt/proto/pf.conf as root
#      * pfctl -t appA_nets -T add 10.0.1.10 (per jail)
#   7. Report success/error

set -eu

# Environment
SSH_KEY="${SSH_KEY:?SSH_KEY not set}"
VM_SSH_PORT="${VM_SSH_PORT:?VM_SSH_PORT not set}"
POLICY_JSON="${POLICY_JSON:?POLICY_JSON not set}"

SCRIPTS="$(cd "$(dirname "$0")" && pwd)"

# ── Validation ─────────────────────────────────────────────────────────────

echo "[1/5] Verifying host dependencies..."

if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq not found — install jq for JSON parsing"
    exit 1
fi

if ! command -v scp >/dev/null 2>&1; then
    echo "ERROR: scp not found"
    exit 1
fi

if ! command -v ssh >/dev/null 2>&1; then
    echo "ERROR: ssh not found"
    exit 1
fi

if [ ! -f "$POLICY_JSON" ]; then
    echo "ERROR: policy file not found: $POLICY_JSON"
    exit 1
fi

echo "[1/5] ✓ jq, scp, ssh available"

# ── Parse JSON ─────────────────────────────────────────────────────────────

echo "[2/5] Validating network-policy.json..."

if ! jq . "$POLICY_JSON" >/dev/null 2>&1; then
    echo "ERROR: JSON syntax error in $POLICY_JSON"
    exit 1
fi

# Extract jail info for logging/validation
JAIL_COUNT=$(jq '.jails | length' "$POLICY_JSON")
echo "[2/5] ✓ JSON valid ($(jq '.version' "$POLICY_JSON") / $JAIL_COUNT jails)"

# Debug: show jails being processed
jq -r '.jails | keys[] as $j | "\($j): ip4=\(.[$j].ip4), pf_enabled=\(.[$j].pf_rules_enabled)"' "$POLICY_JSON" \
    | sed 's/^/           /'

# ── Algorithm Preview (Phase 1 skeleton) ───────────────────────────────────

echo "[3/5] Planning PF rules generation..."

# TODO (Phase 1):
# For each jail in jails[]:
#   if pf_rules_enabled == true:
#     - Read allowed_ports array
#     - Read ip_addr (e.g., "10.0.1.10")
#     - Generate rule:
#       block out quick from <appA_nets> to any
#       pass out quick from <appA_nets> to any port { 80 443 5222 }
#   if ip4 == "disable":
#     - Skip (kernel-level isolation)

echo "[3/5] Phase 1 rules template (stubbed):"
cat <<'RULES'
# Generated from network-policy.json (Phase 1)
#
# appA: email, calendar — strict port whitelist
#   block out quick from <appA_nets> to any
#   pass out quick from <appA_nets> to any port { 80 443 5222 143 25 }
#
# appBrowser: web browsing — open with adblock
#   pass out from <appBrowser_nets>
#
# appB: offline (ip4=disable — no rules needed)
#   # kernel blocks at jail boundary

RULES

echo "[3/5] ✓ Algorithm ready"

# ── Transfer to Guest ──────────────────────────────────────────────────────

echo "[4/5] Transferring policy to guest..."

SCP_OPTS="-P $VM_SSH_PORT -i $SSH_KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

if ! scp $SCP_OPTS "$POLICY_JSON" freebsd@localhost:/tmp/network-policy.json >/dev/null 2>&1; then
    echo "ERROR: scp failed — is VM running? (make vm-wait)"
    exit 1
fi

echo "[4/5] ✓ Transferred to /tmp/network-policy.json"

# ── Call Guest Script (stub) ────────────────────────────────────────────────

echo "[5/5] Calling guest script (STUB — Phase 1 implementation pending)..."

SSH_OPTS="-p $VM_SSH_PORT -i $SSH_KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

# TODO (Phase 1): Implement guest script at /opt/proto-src/scripts/apply-network-policy-guest.sh
# For now, just show what will happen:

echo ""
echo "=== PHASE 1 IMPLEMENTATION PLAN ==="
echo ""
echo "Guest script (/opt/proto-src/scripts/apply-network-policy-guest.sh) will:"
echo "  1. jq parse /tmp/network-policy.json"
echo "  2. Generate /opt/proto/pf.conf with per-jail rules:"
echo "     - appA table + strict port filtering"
echo "     - appBrowser table + open rules (adblock via DNS)"
echo "     - appB: no table (ip4=disable at kernel level)"
echo "  3. Run as root:"
echo "     su -m root -c 'pfctl -f /opt/proto/pf.conf'"
echo "  4. Populate pfctl tables per jail:"
echo "     su -m root -c 'pfctl -t appA_nets -T add 10.0.1.10'"
echo "     su -m root -c 'pfctl -t appBrowser_nets -T add 10.0.1.20'"
echo ""

# Stub: just show JSON contents
echo "=== POLICY JSON (current config) ==="
jq '.' "$POLICY_JSON" | head -30

echo ""
echo "[5/5] ✓ Stub complete — ready for Phase 1 implementation"
echo ""
echo "Next steps:"
echo "  1. Create /opt/proto-src/scripts/apply-network-policy-guest.sh (guest-side)"
echo "  2. Implement jq + printf pf.conf generation"
echo "  3. Test pfctl -f and pfctl -t commands"
echo "  4. Verify: nc -z blocked/allowed ports from within jail"
