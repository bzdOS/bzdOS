# bsdOS Zenoh TLS Configuration

## Quick Start

### 1. Generate certificates

```bash
make gen-tls-certs
```

This creates:
- `/srv/bsdos/certs/ca.pem` — Root CA certificate
- `/srv/bsdos/certs/ca.key` — CA private key
- `/srv/bsdos/certs/server.pem` — Server certificate (for VM)
- `/srv/bsdos/certs/server.key` — Server private key
- `/srv/bsdos/certs/client.pem` — Client certificate (for Mac)
- `/srv/bsdos/certs/client.key` — Client private key

### 2. Deploy certificates to FreeBSD VM

```bash
make vm-wait    # ensure VM is running
make vm-deploy-certs
```

This installs certs to `/etc/bsdos/` on the guest:
- `/etc/bsdos/ca.pem` (644)
- `/etc/bsdos/server.pem` (644)
- `/etc/bsdos/server.key` (600)

### 3. Copy certificates to Mac

```bash
scp certs/ca.pem certs/client.pem certs/client.key user@mac:/etc/bsdos/
```

## Server Configuration

**File:** `certs/zenoh-server-config.json5`

Used on FreeBSD VM:
```bash
ZENOH_CONFIG=/etc/bsdos/zenoh-server.json5 bsdos-core
```

Features:
- **Listen:** TLS on `0.0.0.0:7447`
- **mTLS:** Requires client certificate
- **Auth:** Username/password token (2FA)
- **Keep-alive:** 30 seconds

⚠️ **Change the password token in the config:**
```json5
password: "__CHANGE_ME_UUID_TOKEN__"
```

## Client Configuration

**File:** `certs/zenoh-client-config.json5`

Used on macOS:
```bash
ZENOH_CONFIG=~/.config/bsdos/zenoh-client.json5 bsdos-cli
```

Features:
- **Connect:** To `tls/BSDOS_HOST_IP:7447`
- **mTLS:** Client certificate authentication
- **Auth:** Matching username/password token
- **Self-signed:** Server name verification disabled

⚠️ **Update before deployment:**
1. Replace `BSDOS_HOST_IP` with actual VM IP (e.g., `192.168.1.100`)
2. Match the password token with server config

## Certificate Details

- **Validity:** 10 years (3650 days)
- **Key size:** RSA 4096 (CA), RSA 2048 (server/client)
- **CN:** bsdOS-CA, bsdos-server, bsdos-client
- **Self-signed:** Yes (development)

For production, use a proper CA or Let's Encrypt.

## Security Notes

1. **Protect private keys:**
   - `ca.key` — Keep only on build host
   - `server.key` — Deploy to VM only
   - `client.key` — Deploy to Mac only

2. **Token management:**
   - Use a strong UUID for `password` field
   - Rotate tokens periodically
   - Store in a secrets manager (vault, 1password, etc.)

3. **Firewall:**
   - Port 7447 should be firewalled to trusted networks only
   - Use VPN or SSH tunnel in untrusted environments

## Zenoh Protocol

- **Mode:** peer (no central broker)
- **Transport:** TLS 1.2+ over TCP
- **Routing:** Automatic peer discovery (mdns disabled, static config)
- **Encoding:** Cap'n Proto (binary, zero-copy)

## Troubleshooting

**Certificates not found:**
```bash
ls -la certs/
```

**VM certificate deployment failed:**
```bash
make vm-ssh    # SSH into VM
ls -la /etc/bsdos/
```

**Client connection refused:**
- Check IP/port in client config
- Verify server is running: `pgrep bsdos-core`
- Check firewall: `ssh_guest "nc -l -p 7447"`

**Certificate mismatch:**
- Regenerate: `make gen-tls-certs` (deletes old certs)
- Redeploy: `make vm-deploy-certs`
- Update Mac config with new token
