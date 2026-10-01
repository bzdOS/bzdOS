# SPEC_zenoh_security.md — bsdOS Zenoh Security (mTLS)

**Original plan:** 2026-06-05  
**Promoted to SPEC:** 2026-06-15 (from `docs/archive/2026-06-15-plans/PLAN-zenoh-security.md`)  
**Status:** Active specification  
**Owner:** bsdOS core team

> **⛔ Topic migration 2026-06-13 (commit 1a95431):** examples use new
> per-app_id topics `bsdos/app/{app_id}/{stream,input,health}` instead of
> pre-migration `bsdos/wayland/*`.

**See also:**
- `docs/specs/SPEC_zenoh_keyspace.md` — full key space
- `docs/v0.2-release-plan.md` §F2 — mTLS prototype in Chimp
- `docs/specs/SPEC_chimp_jail_networking.md` — VNET isolation (defense in depth)
- `DESIGN-agent-driven-stack.md` — why we use Zenoh peer mode (no broker)  

## Контекст: Чувствительные данные в Zenoh mesh

Zenoh peer mode (no broker) передаёт **критичные данные в открытом виде** по сети:

| Топик | Тип | Критичность | Пример |
|---|---|---|---|
| `bsdos/wayland/input` | keyboard events, mouse | **КРИТИЧНО** | Keylogger без шифрования |
| `bsdos/wayland/stream` | screen framebuffer | **ВЫСОКАЯ** | Экран видно в пакетах |
| `bsdos/liquid/context` | clipboard, URLs, DRM keys | **ВЫСОКАЯ** | Утечка паролей, credentials |
| `bsdos/ai/request` | LLM prompts, search history | **СРЕДНЯЯ** | Приватные запросы на сервер |
| `bsdos/telemetry` | battery, uptime, CPU temp | **НИЗКАЯ** | Неприватная информация |

**Опасность:** если злоумышленник на одной сети (cafe WiFi, корпоративный VPN, PinePhone <-> Mac в одной комнате), он может:
1. Снифить весь keyboard input → **логирование паролей**
2. Захватить wayland stream → **скриншоты экрана**
3. Украсть clipboard → **API ключи, tokens**

---

## Два архитектурных подхода

### Подход A: WireGuard VPN (рекомендованный)

**Идея:** все Zenoh peers подключаются через приватный WireGuard тоннель перед любой передачей данных.

```
Топология:
┌─────────────┐  WireGuard  ┌──────────────────┐  WireGuard  ┌──────────────┐
│ bsdos-core  │─────────────│ VPN endpoint      │─────────────│ PinePhone    │
│ (Mac/Linux) │ 10.0.0.1    │ (VPS или домашний │ 10.0.0.2    │ (ARM)        │
└─────────────┘ ChaCha20-   │ роутер)           │ ChaCha20-   └──────────────┘
                Poly1305    └──────────────────┘ Poly1305
```

**Конфиг Zenoh (внутри WG):**
```json
{
  "mode": "peer",
  "transport": {
    "tcp": {
      "listen": ["tcp/10.0.0.1:7447"],
      "connect": ["tcp/10.0.0.2:7447"]
    }
  }
}
```

**Плюсы:**
- ✅ Промышленный стандарт (WireGuard одобрен Linux kernel)
- ✅ Очень быстрый (256-bit ChaCha20-Poly1305, ~3% overhead)
- ✅ Мобильный reconnect (IP смена → автоматический re-handshake)
- ✅ NAT traversal через UDP hole punching (если endpoint поддерживает)
- ✅ Простой key management: 2 пары ключей (host A ↔ endpoint, host B ↔ endpoint)
- ✅ Статные: WireGuard в FreeBSD stable, Linux kernel, macOS (Wireguard.app)

**Минусы:**
- ❌ Нужен VPN endpoint (VPS ~$3-5/month, или home router с поддержкой WireGuard)
- ❌ Топология "звезда" → endpoint single point of failure
- ❌ Требует предварительной настройки (не plug-and-play)

---

### Подход B: Zenoh TLS (без VPN)

**Идея:** использовать native Zenoh TLS encryption + digest auth для локального peer authentication.

```rust
// Zenoh 0.11 TLS config (experimental)
{
  "mode": "peer",
  "transport": {
    "auth": {
      "usrpwd": {
        "user": "bsdos",
        "password": "${BSDOS_ZENOH_SECRET}"
      }
    }
  },
  "links": {
    "tls": {
      "enabled": true,
      "server_certificate": "/opt/proto/certs/server.pem",
      "server_private_key": "/opt/proto/certs/server.key"
    }
  }
}
```

**Плюсы:**
- ✅ Standalone — нет VPN endpoint
- ✅ Можно развернуть за 5 минут
- ✅ Self-signed certs подходят для internal mesh

**Минусы:**
- ❌ Zenoh 0.11 TLS всё ещё **experimental** (не для production)
- ❌ Нет NAT traversal — нужна прямая сетевая видимость
- ❌ TLS handshake на каждое соединение → медленнее чем WireGuard
- ❌ Меньше примеров и debugging tools
- ❌ Если скомпрометирован certs на одном хосте → весь mesh открыт

---

## Матрица угроз и Zenoh

| Сценарий | WireGuard | Zenoh TLS | Комментарий |
|---|---|---|---|
| Локальная WiFi (cafe) | ✅ Защита | ✅ Защита | WireGuard безопаснее |
| Корп VPN (shared subnet) | ✅ Защита | ✅ Защита | Оба защищают |
| PinePhone + Mac (разные сети) | ✅ (с endpoint) | ❌ Нет | WireGuard нужен для разных сетей |
| Открытый интернет | ✅ (ChaCha20) | ⚠️ (TLS unproven) | WireGuard рекомендован |
| Компроментирован один peer | ✅ Certs ok | ❌ TLS certs видны | WireGuard безопаснее |
| Keylogging через Zenoh | ✅ Защита | ✅ Защита | Оба шифруют input events |

---

## Рекомендация: WireGuard First

**Решение:** используем **WireGuard VPN как базовую инфраструктуру** для Zenoh.

### Принципы

1. **WireGuard СНАЧАЛА** — до включения любых чувствительных Zenoh топиков
   - `bsdos/wayland/input` → только через WG
   - `bsdos/wayland/stream` → только через WG
   - `bsdos/liquid/context` → только через WG

2. **Telemetry исключение** — можно без WireGuard на локальной сети
   - `bsdos/telemetry` → допустима unencrypted на localhost/LAN
   - Требует явного флага `TELEMETRY_UNENCRYPTED=true`

3. **Double encryption** (Phase 3) — Zenoh TLS поверх WireGuard для extra paranoia
   - Не обязательно, но возможно

4. **Key management** — WireGuard ключи в `/opt/proto/wg/`
   ```
   /opt/proto/wg/
   ├── server-private.key     # бsdos-core приватный
   ├── server-public.key      # всем известный
   ├── pinephone-private.key  # PinePhone приватный
   └── pinephone-public.key   # core пишет в свой конфиг
   ```

---

## Фазовый план реализации

### Phase 0: Локальные тесты (сейчас)

**Компоненты:** только SPICE loopback (localhost) + telemetry на localhost.  
**Безопасность:** всё на 127.0.0.1 → нет сетевой передачи.  
**Zenoh конфиг:**
```json
{
  "mode": "peer",
  "transport": {
    "tcp": {
      "listen": ["tcp/127.0.0.1:7447"]
    }
  }
}
```

**Action:** ничего не меняется, работаем с текущим конфигом.

---

### Phase 1: WireGuard bootstrap (2-3 недели)

**Цель:** развернуть WireGuard mesh на bsdos-core + PinePhone.

**Шаги:**
1. Создать WireGuard конфиг для FreeBSD (host `bsdos-core`) и Linux ARM (PinePhone)
2. Выбрать VPN endpoint:
   - **Вариант A:** Hetzner CAX (arm64) как VPN endpoint (~$4/month)
   - **Вариант B:** Home router с poort-forward (если есть)
3. Сгенерить WireGuard ключи (wg genkey, wg pubkey)
4. Настроить WireGuard интерфейсы:
   - bsdos-core: wg0 → 10.0.0.1/24
   - PinePhone: wg0 → 10.0.0.2/24
   - endpoint: wg0 → 10.0.0.254/24 (NAT/routing)
5. Проверить пингование 10.0.0.0/24
6. Настроить Zenoh на слушание на 10.0.0.x:7447

**Конфиг пример (FreeBSD):**
```sh
# /etc/wireguard/wg0.conf
[Interface]
PrivateKey = <bsdos-core-private-key>
Address = 10.0.0.1/24
ListenPort = 51820

[Peer]
PublicKey = <endpoint-public-key>
Endpoint = vpn.example.com:51820
AllowedIPs = 10.0.0.0/24
PersistentKeepalive = 25
```

**Deliverable:** ✅ WireGuard mesh up, ping 10.0.0.1 <-> 10.0.0.2 < 5ms.

---

### Phase 2: Zenoh migration to WireGuard (1 неделя)

**Цель:** все Zenoh топики передаются только через WireGuard.

**Шаги:**
1. Обновить Zenoh конфиг (привязать на 10.0.0.x вместо 0.0.0.0)
2. Включить критичные топики:
   - `bsdos/wayland/input` ← WireGuard protected
   - `bsdos/wayland/stream` ← WireGuard protected (с compression!)
   - `bsdos/liquid/context` ← WireGuard protected
3. Тестирование:
   - Проверить что unencrypted ports (7447 на 0.0.0.0) не слушают
   - Sniff трафик внутри WG → проверить что никакого plaintext Zenoh

**Конфиг пример:**
```json
{
  "mode": "peer",
  "transport": {
    "tcp": {
      "listen": ["tcp/10.0.0.1:7447"],
      "connect": ["tcp/10.0.0.2:7447"]
    }
  },
  "plugins": {
    "zenoh_transport_tcp": {
      "keepalive": 10
    }
  }
}
```

**Deliverable:** ✅ Wayland input transmitted encrypted end-to-end, tcpdump shows no keyboard plaintext.

---

### Phase 3: Zenoh TLS overlay (опционально, future)

**Цель:** double-encryption для paranoia mode.

**Что:** включить native Zenoh TLS поверх WireGuard.

**Шаги:**
1. Сгенрить self-signed TLS certs для каждого peer
2. Настроить Zenoh TLS в конфиге
3. Проверить что triple encryption (TLS → TCP → WG) работает

**Только если:** нужна compliance или внешний аудит.

---

## Конкретный конфиг для Phase 1

### WireGuard конфиг (bsdos-core, FreeBSD)

```sh
# infra/scripts/wg-setup.sh (нужно создать)
#!/bin/sh
set -e

# 1. Install wireguard
pkg install -y wireguard-tools

# 2. Generate keys (if not exist)
mkdir -p /opt/proto/wg
if [ ! -f /opt/proto/wg/core-private.key ]; then
  wg genkey | tee /opt/proto/wg/core-private.key | wg pubkey > /opt/proto/wg/core-public.key
fi

# 3. Configure wg0
cat > /etc/wireguard/wg0.conf <<EOF
[Interface]
PrivateKey = $(cat /opt/proto/wg/core-private.key)
Address = 10.0.0.1/24
ListenPort = 51820

[Peer]
# VPN endpoint (Hetzner CAX или домашний роутер)
PublicKey = ${WG_ENDPOINT_PUBKEY}
Endpoint = ${WG_ENDPOINT_HOST}:51820
AllowedIPs = 10.0.0.0/24
PersistentKeepalive = 25
EOF

# 4. Bring up wg0
ifconfig wg0 create
wg-quick up wg0

# 5. Add firewall rule (if pf enabled)
echo "pass in proto udp from any to any port 51820" >> /etc/pf.conf
pfctl -f /etc/pf.conf

echo "✓ WireGuard configured on 10.0.0.1:51820"
```

### Zenoh конфиг (Phase 1)

```json
// /opt/proto/zenoh.json (updated)
{
  "mode": "peer",
  "transport": {
    "tcp": {
      "listen": ["tcp/10.0.0.1:7447"],
      "connect": [
        "tcp/10.0.0.2:7447"  // PinePhone WireGuard IP
      ]
    }
  },
  "allow_pub": {
    "policies": [
      {
        "key_expr": "bsdos/**",
        "actions": ["PUT", "DEL"]
      }
    ]
  },
  "plugins": {
    "zenoh_transport_tcp": {
      "keepalive": 10,
      "max_links": 10
    }
  }
}
```

---

## Checklist реализации

- [ ] **Phase 0** ✅ (текущее состояние)
  - [x] Zenoh на localhost:7447
  - [x] Telemetry публикуется

- [ ] **Phase 1** (4-6 недель)
  - [ ] Выбран VPN endpoint (Hetzner CAX или home router)
  - [ ] WireGuard ключи сгенерены и распределены
  - [ ] `infra/scripts/wg-setup.sh` реализован для FreeBSD
  - [ ] `infra/scripts/wg-setup-phone.sh` реализован для PinePhone (Linux ARM)
  - [ ] Проверено ping 10.0.0.1 <-> 10.0.0.2 < 20ms
  - [ ] Zenoh конфиг обновлён (слушает на 10.0.0.x)
  - [ ] Интеграция в Makefile: `make wg-setup`, `make wg-teardown`

- [ ] **Phase 2** (1-2 недели)
  - [ ] `bsdos/wayland/input` публикуется только через WireGuard
  - [ ] `bsdos/wayland/stream` публикуется только через WireGuard (с compression)
  - [ ] `bsdos/liquid/context` публикуется только через WireGuard
  - [ ] Tcpdump проверка: нет plaintext Zenoh на public interfaces
  - [ ] Документация в `INFRA-wireguard.md`

- [ ] **Phase 3** (future, optional)
  - [ ] Zenoh TLS certs сгенерены
  - [ ] Zenoh TLS конфиг заливается
  - [ ] Double-encryption проверена в production

---

## Риски и миtigations

| Риск | Вероятность | Impact | Mitigation |
|---|---|---|---|
| VPN endpoint becomes single point of failure | Средняя | Высокий | Dual VPN endpoints или mesh WireGuard (каждый пир подключается ко всем) |
| WireGuard ключи скомпрометированы | Низкая | Критичный | Хранить в `/opt/proto/wg/` с 0600 permissions, в Makefile добавить warning |
| Phase 1 отнимет больше времени | Средняя | Средний | Начать с Hetzner CAX (проще) вместо home router |
| TLS Phase 3 никогда не реализуется | Высокая | Низкий | TLS опциональна, Phase 2 достаточна |

---

## Выводы

1. **WireGuard — базовая инфраструктура** для bsdOS Zenoh mesh
2. **Phase 0-1-2 timeline:** 6-8 недель до production-ready
3. **Ключевая миtigация:** никогда не публиковать `input`, `stream`, `context` без WireGuard
4. **Telemetry исключение** допустимо только на локальной сети (localhost или LAN /24)
5. **Phase 3 (Zenoh TLS)** — nice-to-have, не критична

**Owner:** core infrastructure team  
**Next review:** 2026-07-01 (after Phase 1 spike)
