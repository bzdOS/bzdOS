#!/bin/sh
set -eu
. "$(dirname "$0")/_ssh.sh"

echo "=== Installing NC-based Matrix Mock ==="

ssh_root "
# Create a simple shell wrapper that responds using nc in loop
mkdir -p /opt/proto/data/appMatrix/bin

cat > /opt/proto/data/appMatrix/bin/conduit << 'SHELL_MOCK'
#!/bin/sh
PORT=8008
echo \"Matrix mock on port \$PORT\"

# Function to process a single request
process_request() {
  local request
  read -r request
  
  # Check if it's the versions endpoint
  if echo \"\$request\" | grep -q '_matrix/client'; then
    printf 'HTTP/1.0 200 OK\\r\\nContent-Type: application/json\\r\\nContent-Length: 117\\r\\n\\r\\n'
    printf '{\"versions\":[\"r0.0.1\",\"r0.1.0\",\"r0.2.0\",\"r0.3.0\",\"r0.4.0\",\"r0.5.0\",\"r0.6.0\"]}'
  else
    printf 'HTTP/1.0 200 OK\\r\\nContent-Type: text/plain\\r\\n\\r\\nOK'
  fi
}

# Start listening
while true; do
  (process_request 2>/dev/null) | nc -l 0.0.0.0 \$PORT 2>/dev/null || true
done
SHELL_MOCK

chmod +x /opt/proto/data/appMatrix/bin/conduit
echo '✓ Mock script created'

# Try to start it
echo '[2] Attempting to start...'
jexec appMatrix pkill -f 'nc -l' 2>/dev/null || true
sleep 1

# Start in background, but within jail
jexec appMatrix /bin/sh -c '/opt/proto/data/appMatrix/bin/conduit &' 2>&1 || echo 'Start failed'
sleep 2

# Check if something is listening
jexec appMatrix ss -tln 2>/dev/null | grep 8008 && echo '✓ Port 8008 listening' || echo '⚠ Port not listening'
"

# Test from outside
echo "[3] Testing from outside..."
ssh_root "
sleep 1
RESPONSE=\$(jexec appMatrix sh -c 'printf \"GET /_matrix/client/versions HTTP/1.0\\r\\nHost: localhost\\r\\n\\r\\n\" | nc -w 1 localhost 8008' 2>/dev/null | head -20 || echo 'FAILED')

echo 'Response:'
echo \"\$RESPONSE\"

if echo \"\$RESPONSE\" | grep -q 'versions'; then
    echo ''
    echo '✓✓✓ SUCCESS!'
else
    echo ''
    echo '⚠ Response problem'
fi
"

