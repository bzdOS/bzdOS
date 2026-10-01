# SPEC_net_v1 — bsdOS Decentralised Network

> **STATUS: DESIGN / not implemented.** Companion к `SPEC_coupling_v1`.
> Date: 2026-07-04. Related: `docs/specs/SPEC_coupling_v1.md`, `docs/specs/SPEC_zenoh_security.md`,
> `docs/specs/SPEC_zenoh_keyspace.md`, `docs/specs/SPEC_chimp_zenoh.md`.
>
> **Одно предложение:** сеть — это coupling-managed ресурс, не отдельный зоопарк;
> два уровня — overlay (узел↔узел, Zenoh-mesh поверх obfs/TLS:443) и ingress
> (мир→сервис, взаимозаменяемые публичные «двери»); couplingd = control-plane для обоих.
>
> **Решение 2026-07-04: WireGuard-overlay отвергнут.** Причины: (1) ТСПУ (российский DPI)
> фингерпринтит и режет WireGuard — детерминированный handshake + характерные размеры пакетов
> → throttle/block; (2) WG = отдельный зоопарк-компонент (WG + cloudflared + Zenoh + couplingd),
> противоречит принципу «одна ось, не зоопарк». Замена: **Zenoh peer-mesh поверх obfs/TLS на
> порту 443** — уже используется (obfs dev-vm:443, Mac↔сервер, DPI-стоек, проверено).

## 0. Философия (co-design с SPEC_coupling_v1)

SPEC_coupling_v1 §0: «прячь швы, которые можешь; делай явным тот один, что не можешь».
Сеть следует той же логике:

- **Что прячем:** NAT узлов, выбор relay, смену IP публичных нод, failover «двери» ingress.
  Оператор видит одну систему; jail никогда не называет коробку по IP.
- **Что явно:** синхронная кросс-сайт запись (§5 coupling_v1 = единственный шов) требует
  кворума, который недостижим если все публичные ноды упали. Это физика, не баг — её называем.
- **Не зоопарк:** peer-конфигурация = CRDT; membership = Zenoh liveliness; выбор relay =
  coupling-lock; eviction = сетевой fence (отзыв членства в Zenoh-роутере). Сеть — такой
  же coupling-managed ресурс, как хранилище или jail. Один транспорт: Zenoh поверх obfs:443.

Три яруса coupling_v1 живут поверх этой сети без переписывания:

```
┌─────────────────────────────────────────────────────┐
│  Ярус 3: CRDT write-anywhere (Zenoh delta-CRDT)     │ AP,   coordination-free
│  Ярус 2: coupling-store (flock+fence, RaftLog WAN)  │ CP,   кворум
│  Ярус 1: HA failover (jail+ZFS+fence reschedule)    │ авт.  прозрачно
├─────────────────────────────────────────────────────┤
│  overlay: Zenoh-mesh поверх obfs/TLS:443            │  ← этот документ
│  ingress: публичные «двери» + svc-steering           │  ← этот документ
└─────────────────────────────────────────────────────┘
```

---

## 1. Два независимых плана (не путать)

Гетерогенный кластер: **публичные узлы** (серверы в ЦОД, белый IP, достижимы из интернета)
и **NAT-узлы** (личные машины, роутер, нет входящих).

Эти два типа нод дают два независимых слоя:

| Слой | Функция | Кто участвует |
|---|---|---|
| **Overlay** | узел↔узел (mesh) | все ноды — публичные + NAT |
| **Ingress** | мир→сервис (доступ снаружи) | ЦОД-ноды (direct) + NAT-ноды (через CF Tunnel) |

Разделение по механизму, не по членству: ЦОД-нода = прямая «дверь» (A-record); NAT-нода =
«дверь через CF-туннель» (обратный relay). Обе — полноправные serving-члены. Требование
белого IP снято для serving; осталось только для join-bootstrap (§5).

**Зафиксировано 2026-07-04:** NAT-ноды — полноправные serving-члены (§3.3, §3a).

---

## 2. Overlay — Zenoh-mesh поверх obfs/TLS:443

### 2.1 Топология

Zenoh peer-mesh поверх obfs/TLS-транспорта на порту 443. Никакого нового компонента:
тот же obfs-стек уже используется (проверено: Mac↔сервер 192.0.2.10:443, DPI-стоек).
DPI/ТСПУ видит HTTPS-подобный поток на 443 — не WireGuard handshake.

```
      публичная-A         публичная-B
      (белый IP)          (белый IP)
      Zenoh-router        Zenoh-router
      :443 (obfs/TLS)     :443 (obfs/TLS)
         │  ╲           ╱  │
  Zenoh  │   ╲─────────╱   │  Zenoh
  peer   │    ╲       ╱    │  peer
         │   NAT-ноды       │
         │  (исходящие      │
         │   к публичным    │
         │   роутерам)      │
         ╲─────────────────╱
          Zenoh peer-mesh
          (obfs/TLS:443)
```

**Что потеряли vs WireGuard (плоский L3, произвольный TCP-порт по overlay-IP):**
не нужно — координация идёт через Zenoh, NAT inbound = CF Tunnel (§3), NAT outbound = прямой
исходящий коннект, ZFS-реплика на NAT-ноду = нода тянет сама исходящим. Единственный
сценарий raw-TCP к произвольному порту NAT-ноды снаружи → CF Tunnel (§3a).

### 2.2 Роли нод в Zenoh-mesh

**Публичные ноды (ЦОД, белый IP):**
- Запускают `zenohd` в режиме `router` (или `peer`), слушают обfuscated TLS на порту 443.
- Служат точками входа для NAT-нод (rendezvous + relay pub/sub).
- Также = bootstrap seed для `bsdos join` (§5).

**NAT-ноды (личные машины, роутер):**
- Устанавливают **исходящее** Zenoh-соединение к ближайшей публичной ноде (443/TLS).
- NAT traversal встроен: исходящий TCP через NAT проходит без дополнительных компонентов.
- Через публичный роутер участвуют в полном pub/sub mesh.

### 2.3 Идентичность узла = Zenoh-сессия/ключ

Криптографическая идентичность узла = TLS-сертификат (mTLS, см. SPEC_zenoh_security.md).
`couplingd` ведёт таблицу `(node_id → zenoh_peer_id → public_endpoint | null)` как CRDT
(OR-Map, LWW). Membership = Zenoh liveliness (см. §4).

**Eviction = отзыв доступа:** узел исключён из кластера → `couplingd` отзывает его
членство (удаляет из авторизованного peer-set CRDT; публичные роутеры перестают принимать
его соединения). Механизм аналогичен fencing-токену coupling_v1 §8: мертвецу не дают
писать — здесь мертвецу не дают подключаться к роутерам.

### 2.4 Zenoh конфигурация (obfs:443)

Zenoh работает в peer (или router) mode, транспорт = obfs/TLS поверх TCP:443.

```json
{
  "mode": "peer",
  "transport": {
    "unicast": {
      "lowlatency": false,
      "tls": {
        "client_auth": true,
        "server_name": "bsdos-router"
      }
    }
  },
  "connect": {
    "endpoints": ["tls/192.0.2.10:443"]
  }
}
```

Список peers = публичные роутеры из seed-конфига. Синхронизируется через CRDT peer-set (§4).
Шифрование = TLS (mTLS поверх obfs) — один слой, нет double-encryption.
Obfs-обёртка: тот же механизм что на dev-vm:443, делает трафик DPI-непрозрачным.

### 2.5 Транспорт-агностичность: одна mesh-абстракция, открытый набор линков (зафиксировано 2026-07-05)

**Требование:** заранее НЕ известно, какой маршрут заработает (obfs / собственный домен /
прямой SSH / …), а в будущем возможны экзотические каналы (IoT-радио, LoRa). Поэтому меш и
транспорты должны быть **независимы**.

**Развязка двух плоскостей:**
- **Меш-плоскость** (Matrix/CRDT/coupling) требует ровно одного контракта: «рано или поздно
  доставить байты между репликами». Транспорт-агностична by construction — CRDT сходится при
  любой доставке (любой порядок, задержки, разрывы). Это и есть «координация деградирует до
  синка»: синк едет по любому каналу.
- **Транспорт-плоскость** — открытый плагинный набор ЛИНКОВ: obfs-443, собственный домен
  (TLS), проброшенный SSH (TCP), IoT-радио (`zenoh-link-radio` или мост радио↔Zenoh на
  ноде-шлюзе), LoRa, … Несколько активны одновременно. Добавить транспорт = добавить Zenoh-линк,
  **меш не трогается.**

**Это НЕ противоречит §2 «один транспорт».** «Один» = одна mesh-абстракция (Zenoh), НЕ зоопарк
оверлеев (WG + CF-как-оверлей + Zenoh). Несколько ЛИНКОВ под одной мешой ≠ зоопарк; зоопарк =
несколько независимых оверлей-СИСТЕМ. Итог: **одна ось (Zenoh) + открытый набор линков под ней
+ happy-eyeballs failover между локаторами (§3b).** `zenoh-link-obfs` (уже пропатчен) — один
линк, а не весь транспорт.

**Следствие для «не знаю, что заработает»:** нода публикует в дескрипторе (§3b.3) ВСЕ свои
локаторы по всем доступным линкам; клиент гонит их наперегонки и берёт первый живой. Ничего не
выбирается заранее. Модель кода уже это держит: локатор — opaque строка (§3b.6), её линк-тип
(tls / obfs / radio / …) меша не касается.

**Оговорка по полосе:** агностичность держится для control/event-плоскости (Matrix-события,
coupling, CRDT-дельты — мелкие, едут даже по радио). Высокополосный data-plane (wl_shm
видеострим) по узкому каналу — отдельный вопрос, «синк по чему угодно» его не покрывает.

---

## 3. Ingress — гибридная модель (ЦОД-direct + NAT-reverse-relay)

### 3.1 Модель

Внешний клиент (браузер, Matrix-клиент, другой сервер) видит один DNS-name (`svc.домен`).
**Путь зависит от того, где сейчас живёт сервис:**

```
внешний клиент
      │ HTTPS/TCP (одно имя: svc.domain)
      ▼
  Cloudflare DNS
      ├─── A-record, proxied=false → [ЦОД-нода: 1.2.3.4]          ← прямой путь
      │         │ Zenoh-mesh (obfs:443)
      │         ▼
      │    couplingd → svc-registry → конкретный jail
      │
      └─── CNAME → <tunnel_id>.cfargotunnel.com, proxied=true      ← CF-relay путь
                │
                ▼  (Cloudflare edge)
           cloudflared (NAT-нода, исходящий туннель)
                │ Zenoh-mesh (obfs:443)
                ▼
           couplingd → svc-registry → конкретный jail
```

**Важно:** клиент бьёт в одно имя; маршрут (direct vs CF) определяет `cf-router` (§3a)
на основании svc-registry и метадаты ноды. Jail адресован через Zenoh-routing (node_id + порт).

### 3.2 Дефолтная конфигурация ingress (зафиксировано 2026-07-04)

| Тип ноды | Ingress-механизм | DNS-запись |
|---|---|---|
| **ЦОД-нода (публичный IP)** | Прямой A-record; CF не в тракте | `A svc.домен = <public_ip>`, `proxied=false` |
| **NAT-нода** | Reverse-relay через Cloudflare Tunnel (`cloudflared`) | `CNAME svc.домен = <tunnel_id>.cfargotunnel.com`, `proxied=true` |

**Паттерн:** Cloudflare Tunnel (аналог Cloudflare Tunnel / frp / Tailscale Funnel).
`cloudflared` на NAT-ноде держит постоянное исходящее соединение к Cloudflare edge;
edge принимает входящий HTTPS и пробрасывает в туннель. NAT-нода — полноправный serving-член:
она отвечает наружу, не только хранит реплику.

**Cloudflare = авторитативный DNS + relay для NAT.** Для ЦОД-нод CF — только DNS (не в тракте).
Для NAT-нод CF-edge = дверь.

### 3.3 NAT-ноды — полноправные serving-члены

NAT-ноды **являются** serving-членами кластера, а не только репликами. Они:
- Участвуют в overlay (CRDT, хранение, вычисления) — как прежде.
- **Обслуживают внешние запросы** через reverse-relay (CF Tunnel): трафик идёт CF-edge → cloudflared → Zenoh-mesh → jail.
- Не требуют port-forwarding, UPnP, публичного IP.
- Недостижимы из публичного интернета напрямую; доступны через mesh-пиров (Zenoh через роутер) или CF Tunnel.

### 3.4 Мульти-инстанс и балансировка

- **Singleton** (PG, unique stateful): одна DNS-запись; failover = `cf-router` переписывает запись при смене ноды.
- **Stateless workers**: Cloudflare Load Balancer pool с несколькими origins (ЦОД direct-origins + NAT tunnel-origins); health-check per-origin; CF LB делает балансировку и failover прозрачно для клиента.

---

## 3a. cf-router — динамический ingress-роутинг

### 3a.1 Назначение

`cf-router` — reconciler (тот же паттерн, что jail-reconcile в coupling_v1 §13).
**Истина:** `couplingd` svc-registry (`svc:X → нода N`) + метадата ноды (`public_ip: Some|None`, `cf_tunnel_id: Option<String>`).
**Задача:** привести Cloudflare к желаемому состоянию при каждом изменении svc-registry.

### 3a.2 Алгоритм reconcile

```
cf-router слушает: KV WATCH svc:* + KV WATCH bsdos/net/node/*

on event(svc:X changed to node N):
  meta = KV GET bsdos/net/node/N   # public_ip, cf_tunnel_id
  if meta.public_ip is Some(ip):
    CF API → DNS upsert: A X.домен = ip, proxied=false      # ЦОД-direct
  elif meta.cf_tunnel_id is Some(tid):
    CF API → DNS upsert: CNAME X.домен = tid.cfargotunnel.com, proxied=true  # NAT-relay
  else:
    # нода недостижима снаружи — не создавать запись, alert
```

Переезд сервиса (failover jail→другая нода) → cf-router перепрограммирует CF через API автоматически.

### 3a.3 Место в архитектуре

- **Stateless воркер:** cf-router не держит локального состояния; несколько экземпляров безопасны (CF API идемпотентен).
- **Реализация:** часть `couplingd` (один бинарь, отдельный reconcile-task), не отдельный демон.
- **Credentials:** scoped CF API-токен (`Zone:DNS:Edit` для своей зоны); хранится в coupling-store как секрет.

### 3a.4 Failover-latency

| Сценарий | Latency переключения |
|---|---|
| NAT-нода умерла (CF proxied=true) | Мгновенно на CF-edge (CF детектирует падение туннеля) |
| ЦОД-нода умерла (direct A-record) | DNS TTL (30–60 сек) ИЛИ CF LB health-check (<10 сек при LB) |
| Сервис мигрировал (failover jail) | cf-router reconcile + CF API propagation (~сек) |

### 3a.5 Честные границы (швы)

- **CF — третья сторона в NAT-пути:** CF SPOF для NAT-нод serving наружу. ЦОД-direct не зависит от CF.
- **CF API credentials** — scoped (только DNS в своей зоне); компрометация токена = DNS-манипуляции в пределах зоны.
- **DNS TTL-лаг для direct:** при отказе ЦОД-ноды (no LB) клиенты с кешированным старым A могут не переключиться сразу.
- **NAT + CF = две точки отказа** в цепочке (NAT-машина + CF edge) вместо одной (ЦОД).

### 3a.6 Milestones (ingress-специфичные)

- **N3a** cf-router базовый: KV WATCH svc:* → CF API upsert (A/CNAME) при смене ноды.
- **N3b** cloudflared на NAT-нодах: скрипт `bsdos tunnel init` → регистрирует туннель, пишет `cf_tunnel_id` в node-метадату.
- **N3c** CF LB pool для stateless workers: pool с ЦОД + NAT origins, health-check.
- **N3d** Fallback-alert: нода без public_ip и cf_tunnel_id → cf-router пишет предупреждение, запись не создаётся.

---

## 3b. Мульти-маршрут: один эндпоинт, N дверей

### 3b.1 Идея

Модель §3 (direct A **xor** CF Tunnel) ограничивает нод одним ingress-маршрутом в каждый
момент. §3b обобщает: **один локальный слушатель** на ноде может быть достижим по нескольким
независимым путям одновременно. Клиент получает все пути и выбирает лучший
(happy-eyeballs), а при отказе одного — прозрачно переключается на другой.

### 3b.2 Три класса маршрутов

| Класс | Описание | `proxied` | Пример локатора |
|---|---|---|---|
| **Internal** | Приватный/mesh адрес, достижимый внутри доверенного overlay | нет | `100.64.0.2:7447` |
| **Public** | Прямой публичный IP (ЦОД-нода, белый IP) | нет | `1.2.3.4` |
| **Cloudflare** | Публичный hostname через исходящий CF Tunnel (NAT-нода) | да | `<tid>.cfargotunnel.com` |

Нода может иметь **любое непустое подмножество** классов одновременно:

| Тип ноды | Доступные классы |
|---|---|
| ЦОД-нода без overlay-адреса | {Public} |
| ЦОД-нода в overlay | {Internal, Public} |
| NAT-нода в overlay | {Internal, Cloudflare} |
| Нода со всеми тремя | {Internal, Public, Cloudflare} |

### 3b.3 Node descriptor и Zenoh KV

Каждая нода публикует свои маршруты-по-классам в `bsdos/net/node/<node_id>` как Cap'n Proto
структуру (расширение существующего liveliness-ключа из §9). Клиент читает дескриптор и
получает упорядоченный список локаторов.

```
bsdos/net/node/<node_id>:
  routes:
    - class: Internal,    locator: "100.64.0.2:7447",              proxied: false
    - class: Public,      locator: "1.2.3.4",                      proxied: false
    - class: Cloudflare,  locator: "abc123.cfargotunnel.com",       proxied: true
```

Порядок в дескрипторе = порядок предпочтений: Internal → Public → Cloudflare.
Это порядок для `connect.endpoints` в Zenoh — Zenoh нативно гонит несколько эндпоинтов и
делает failover без дополнительного кода.

### 3b.4 Схема happy-eyeballs и приоритизация

```
Клиент (mesh-local):              Клиент (внешний интернет):
  1. Попробовать Internal            1. Попробовать Public (прямой A)
  2. Попробовать Public              2. Попробовать Cloudflare (CNAME→tunnel)
  3. Попробовать Cloudflare          3. Попробовать Internal (если знает адрес)
  → первый отвечает — выиграл        → первый отвечает — выиграл
```

В коде (`cf_router.rs`, `select_route(routes, on_internal_mesh)`) это реализовано как чистая
функция: никакого реального зондирования, только политика + хинт `on_internal_mesh`.
Реальный гейс/failover выполняет Zenoh через `connect.endpoints` при подключении.

```
                  ┌─────────────────────────────────────────────────┐
                  │             Нода X (один слушатель :7447)        │
                  │                                                   │
  внешний клиент──┤──CF-edge──cloudflared──→[Cloudflare]             │
                  │                                                   │
  ЦОД-peer ───────┤──────── прямой TCP ─────→[Public IP]             │
                  │                                                   │
  mesh-клиент ────┤──── overlay (obfs:443) ──→[Internal 100.x]       │
                  │                                                   │
                  │    все три → один и тот же :7447 listener         │
                  └─────────────────────────────────────────────────┘
```

### 3b.5 Двухуровневая отказоустойчивость

```
Ярус 1 (маршрутный): ≥1 дверь живёт → нода достижима.
Ярус 2 (реплики):    ≥1 реплика сервиса жива → сервис отвечает.
────────────────────────────────────────────────────────
Система отвечает «до последнего сервера»:
  последний сервер + хоть одна дверь = клиент получает ответ.
```

Это дополнение к CAP-анализу в §6: ingress теперь AP не только по репликам, но и по путям
(route-level AP) — отказ CF не роняет ЦОД-direct; отказ публичного IP не роняет CF Tunnel.

### 3b.6 Internal-локатор: opaque, потребляется — не усыновляется (разрешено 2026-07-05)

**Принцип (снимает ложную дихотомию A/B):** использовать приватный адрес, который у ноды
УЖЕ есть, ≠ тащить компонент в ось. Класс Internal — это **opaque node-provided локатор**;
bsdOS его только потребляет, не управляет его источником.

**Как это работает.** Нода кладёт в свой дескриптор (§3b.3) один Internal-локатор — любой
приватный адрес, по которому она достижима: Zenoh-mesh-пир, LAN-IP, или — если нода по своим
причинам уже держит Tailscale — её `100.x` адрес. bsdOS видит только строку и маршрутизирует
по ней (`routes_for`/`select_route`); природа адреса ему безразлична.

**Конкретный кейс — workstation-нода.** Машина уже имеет Tailscale (независимо от нас) и вступает
в кластер как обычный Zenoh-mesh-член. Её `100.x` = её Internal-локатор. Личные устройства
пользователя (в том же tailnet) заходят в кластер **через неё** как через Zenoh-entry-point —
приватно, без obfs/ssh-L. То есть ingress для tailnet-устройств роутится через workstation-ноду,
потому что она достижима и в tailnet, и в Zenoh-mesh. Tailscale здесь — свойство ноды, а не
компонент bsdOS.

**Граница (чего bsdOS НЕ делает):** не ставит tailscaled на НАШИ ноды, не поднимает
Tailscale-координатор/Headscale, не зависит от Tailscale. Overlay остаётся Zenoh-mesh поверх
obfs:443 — **§2 цел: WireGuard как НАШ транспорт по-прежнему отвергнут.** Мы потребляем
адрес, который нода и так предоставляет, а не усыновляем компонент. Разница «потреблять адрес
vs усыновлять компонент» и есть разрешение A/B.

**Позиция кода (без изменений):** `NodeMeta.internal_addr: Option<String>` — opaque строка;
`routes_for()`/`select_route()` работают с любым значением. Ровно та модель, что нужна:
политика (что нода кладёт в Internal-локатор) отделена от механики (как маршрутизировать).

---

## 4. Сеть как coupling-managed ресурс

couplingd (один бинарь на узел) — control-plane и для сети. Не новый демон.

### 4.1 Peer-set как CRDT

Таблица `(node_id → zenoh_peer_id → public_endpoint | null)` хранится как
OR-Map с LWW-регистрами. Распространяется через Zenoh delta-CRDT на `bsdos/net/peers`.
Любая нода, получившая дельту, обновляет свой список Zenoh-эндпоинтов для подключения.

```
couplingd получил дельту peers →
  for each new_peer in delta:
    # если у ноды есть public_endpoint — добавить в zenoh connect-list
    zenoh_config.add_endpoint(new_peer.public_endpoint)
  for each removed_peer in delta:
    # убрать из connect-list, при eviction — из авторизованного peer-set
    zenoh_config.remove_peer(removed_peer.node_id)
```

### 4.2 Membership через Zenoh liveliness

Каждая нода публикует liveliness token на `bsdos/net/node/<node_id>`.
Пропадание liveliness = нода умерла. couplingd всех живых нод видит это через Zenoh
liveliness-subscriber. Мертвая нода → TTL lease истёк → все её svc-регистрации сняты
(coupling_v1 §3 «Session/Lease — корень»).

### 4.3 Relay через публичный Zenoh-роутер

NAT-нода A не может принять входящее соединение от NAT-ноды B — pub/sub автоматически
идёт через публичный Zenoh-роутер (встроено в протокол: NAT-нода A и NAT-нода B
оба подключены к роутеру исходящим, роутер ретранслирует pub/sub между ними).
Нет separate relay-демона, нет hole-punch: Zenoh router = relay по дизайну.

Выбор конкретного роутера = `LOCK ACQ relay:<nodeA>-<nodeB>` через coupling-store,
если у нод несколько публичных роутеров и нужен детерминированный выбор. Lock
гарантирует один маппинг без конфликтов.

### 4.4 Svc-registry как Zenoh-steering

`SVC REG svc:matrix-synapse <node_id>:<local_port> <session>` — couplingd регистрирует
живой jail (адрес = node_id + порт, не overlay-IP).
Ingress-proxy на публичной ноде резолвит `svc:matrix-synapse` → находит node_id →
маршрутизирует через Zenoh к couplingd на целевой ноде → локальный jail.
Смерть узла → lease истёк → svc снят → следующий `RESOLVE` вернёт другой instance (если есть).

---

## 5. Bootstrap — вход в кластер

### 5.1 `bsdos join`

```
$ bsdos join 1.2.3.4
```

1. Нода генерирует TLS-keypair (или переиспользует существующий).
2. Исходящее Zenoh-подключение к публичной ноде `1.2.3.4:443` (obfs/TLS).
   Никакого WireGuard handshake — DPI видит TLS-подобный поток на 443.
3. Публичная нода аутентифицирует через mTLS challenge (сертификат новой ноды).
4. Публичная нода возвращает снапшот peer-set CRDT (`bsdos/net/peers`).
5. Новая нода применяет peer-set: добавляет известные публичные ноды как Zenoh-эндпоинты,
   присоединяется к mesh, публикует liveliness на `bsdos/net/node/<node_id>`.
6. couplingd всех живых нод получает delta → обновляет свой connect-list.

**Любая публичная нода обслуживает join** — нет выделенного координатора.

### 5.2 Отказ при bootstrap

Если нода, к которой присоединяемся, недоступна — пробуем следующую публичную из локально
известного seed-списка (в конфиге `/usr/local/etc/bsdos/net.conf`). Если все seed'ы недоступны —
join отклоняется с ошибкой (не тихо).

---

## 6. Честный CAP-анализ («до последнего сервера»)

Требование: система отказоустойчива «до самого последнего сервера». Разбираем честно.

### 6.1 Reads / CRDT-состояние (Ярус 3) — AP

Любая живая нода отдаёт данные. Quorum не нужен. Сходимость гарантирована (Strong Eventual
Consistency). Работает пока жива ≥1 нода. Ограничение: читаем possibly stale данные
(реплика может отставать). Это заявлено в coupling_v1 §6 как честная граница CRDT.

### 6.2 Strong-write / coupling-store (Ярус 2) — CP

RaftLog (WAN) требует кворума. Если живых нод < кворума — **strong-write недоступна**.
Это честный CAP: нельзя иметь и partition-tolerance, и линеаризуемость, и availability.
Проектное решение: держать ≥3 нод, участвующих в Raft (публичные — наиболее стабильны).

### 6.3 Внешний ingress — AP по дверям

Ingress жив пока жива ≥1 публичная нода с сервисом за ней. Несколько публичных нод = несколько
дверей. DNS health-check или anycast направляет трафик в живую. Требование: **≥2 гео-разнесённых
публичных ноды** для ingress HA — это минимально разумный барьер.

### 6.4 Внутренний mesh

Если все публичные ноды умерли, а NAT-ноды друг с другом связаны напрямую (или через выживший
relay) — внутренний mesh + CRDT-состояние живут дальше. Внешний доступ невозможен (нет дверей),
но система не теряет данных и продолжает внутреннюю работу.

---

## 7. Стены (честно назвать)

| Стена | Последствие | Смягчение |
|---|---|---|
| **ТСПУ / DPI** | WireGuard был бы зарезан (детерминированный handshake, характерные размеры пакетов). **Zenoh поверх obfs/TLS:443 проходит:** DPI видит HTTPS-подобный поток — нет характерных паттернов WG. Проверено на маршруте Mac→dev-vm:443. | Транспорт = obfs:443; никаких WG-специфичных пакетов |
| **NAT-нода: нет входящих** | Внешний интернет-клиент не может подключиться к NAT-ноде напрямую. Mesh (Zenoh pub/sub) работает через публичный роутер исходящим. | CF Tunnel для serving наружу; mesh-координация через роутер |
| **Все публичные ноды умерли** | Внешний ingress недоступен; new join невозможен; NAT-ноды изолированы от внешнего мира; strong-write теряет кворум | Держать ≥2 гео-разнесённых публичных; мониторинг |
| **Strong-write < кворума** | LOCK ACQ / CAS / линеаризованные операции недоступны; CRDT и stale-reads — живы | Проектировать под CRDT-first; координацию — только для действительно не merge-замкнутых инвариантов |
| **Bootstrap без seed** | Join отклоняется | Hardcode ≥2 публичных IP как seed в конфиге |
| **Eviction: нода продолжает работать локально** | Evicted нода сохраняет локальные данные; доступ к Zenoh-роутерам заблокирован → не участвует в mesh | Lease-eviction в coupling-store истекает — svc-регистрации сняты, jail failover запущен |
| **CF SPOF для NAT-serving** | Cloudflare outage → NAT-ноды перестают обслуживать внешних клиентов (ЦОД-direct не затронуты) | Критичные stateful сервисы — prefer ЦОД-direct; мониторить CF-статус |

---

## 8. Идентичность и безопасность

| Аспект | Механизм |
|---|---|
| **Идентичность узла** | TLS-сертификат (mTLS); генерируется при первом старте, хранится локально |
| **Шифрование overlay** | TLS поверх obfs на порту 443; весь Zenoh-трафик и coupling внутри |
| **Аутентификация join** | mTLS при Zenoh-подключении: новая нода предъявляет сертификат, публичная нода — свой |
| **Membership** | `couplingd` ведёт авторизованный peer-set (CRDT); неавторизованный сертификат отклоняется роутером |
| **Eviction** | Удаление из CRDT peer-set → роутеры закрывают соединение с evicted нодой |
| **Ingress TLS** | Caddy / обратный прокси на публичной ноде (отдельный от Zenoh-TLS) |
| **Zenoh ACL** | Per-key ACL поверх mesh (SPEC_zenoh_keyspace.md §Authorization) |

Overlay шифрован и аутентифицирован конца в конец через mTLS. NAT-узел не имеет доступа
к Zenoh-ключам без авторизованного сертификата в peer-set.

---

## 9. Ключи Zenoh (сеть)

Дополнение к SPEC_zenoh_keyspace.md. Новые ключи, добавляемые этим спеком:

| Ключ | Тип | Описание |
|---|---|---|
| `bsdos/net/peers` | CRDT OR-Map (Cap'n Proto delta) | peer-set: node_id → zenoh_peer_id → pub_endpoint (obfs:443) |
| `bsdos/net/node/<node_id>` | Zenoh liveliness token + Cap'n Proto route descriptor | membership heartbeat; исчезновение = нода умерла; payload = маршруты-по-классу (§3b.3) |
| `bsdos/net/relay/<a>/<b>` | `LockGrant` (coupling §3) | выбранный relay для пары NAT-нод |
| `bsdos/net/svc/<name>` | CRDT LWW (overlay_ip, fence) | svc-registry entry (alias к coupling svc) |

---

## 10. Отображение на существующие кирпичи

| Кирпич | Роль в сети |
|---|---|
| **obfs/TLS:443** | транспорт overlay; obfuscation → DPI-непрозрачность; TLS = шифрование + mTLS-аутентификация |
| **Zenoh peer-mode / router** | mesh pub/sub + CRDT delta-sync + liveliness поверх obfs:443; публичные ноды = роутеры, NAT-ноды = peer (исходящий к роутеру) |
| **Cap'n Proto** | формат peer-set дельт, relay-grants, svc-entries (zero-copy) |
| **couplingd** | control-plane: peer-set sync, relay-lock, svc-registry, eviction |
| **CRDT (Ярус 3)** | peer-set, svc-записи, конфиг нод — write-anywhere, без координации |
| **RaftLog WAN (Ярус 2)** | strong-write кворум для линеаризованных операций |
| **jails** | единица размещения сервисов; адрес = node_id + порт, не overlay-IP |
| **DNS / anycast** | внешний ingress steering (выбор публичной «двери») |

---

## 11. Milestones (порядок сборки, поверх coupling_v1 M0–M5)

- **N0** Zenoh-mesh через obfs:443: ручная настройка — запустить `zenohd` с obfs/TLS на публичных нодах; убедиться, что NAT-нода подключается исходящим. Нет WireGuard, нет отдельного компонента.
- **N1** `bsdos join`: Zenoh-подключение к seed-роутеру:443, получение peer-set CRDT, liveliness. NAT-нода входит в mesh без ручной настройки.
- **N2** NAT-нода: исходящий Zenoh к публичному роутеру; relay = сам роутер (встроено в Zenoh). Автоматический выбор роутера через coupling-lock при нескольких роутерах.
- **N3** Ingress: cf-router базовый + cloudflared на NAT-нодах + CF DNS steering. Детали: §3a.6 (N3a–N3d).
- **N4** Eviction: удаление из CRDT peer-set через couplingd при lease-expiry → роутеры закрывают коннект. Тест: убитая нода не переподключается.
- **N5** Bootstrap hardening: seed-list в конфиге, retry всех seed'ов, ошибка если все недоступны.

Зависимость: N0 блокирует coupling_v1 M0 в multi-node режиме. N1 = prerequisite для M0 SSI-UX.

---

## 12. Открытые вопросы (нужен вход пользователя)

1. **Количество и гео публичных нод.** Текущий кластер: сколько публичных IP? В каких датацентрах/странах?
   Минимум для ingress HA = 2 разных площадки. Минимум для Raft-кворума = 3 участника (могут
   быть смешаны публичные + стабильные NAT с port-forward).

2. **Количество NAT-нод.** Сколько личных машин планируется? Есть ли port-forwarding / UPnP?
   Для Zenoh-mesh тип NAT не критичен (исходящий TCP всегда проходит); важно только для
   CF Tunnel (нужен cloudflared на нодах с serving-нагрузкой).

3. **Что ОБЯЗАНО быть strong cross-site vs eventual/CRDT.** Какие инварианты не merge-замкнуты?
   (Примеры: уникальный username, баланс ≥ 0, владение файлом.) Всё остальное → CRDT.
   Без этого ответа нельзя правильно выставить `coupling.role` для каждого сервиса.

4. **Домен и DNS-провайдер.** ~~Открытый вопрос.~~ **Решено 2026-07-04:** Cloudflare = авторитативный DNS + Tunnel.
   CF API-токен (scoped `Zone:DNS:Edit`) нужен для cf-router. Домен должен быть делегирован Cloudflare NS.

5. **AS и anycast.** Есть ли автономная система (AS-номер) и PI IP-блок?
   Anycast даёт ingress failover без TTL-задержки DNS, но требует BGP-сессии с провайдером.
   С CF LB — менее актуально для большинства сценариев.

6. **Bootstrap seed-список.** Конкретные публичные IP, которые войдут в hardcoded seed-list конфига.
   Нужны до N1.

7. **obfs-конфигурация.** Какой obfs-метод используется (obfs4, shadowsocks-подобный, кастомный)?
   Нужно согласовать конфигурацию obfs на публичных роутерах с той, что уже работает на dev-vm:443.
