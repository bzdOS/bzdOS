# SPEC_chimp_jail_networking.md — VNET jails для сетевой изоляции

**Original plan:** 2026-06-05  
**Promoted to SPEC:** 2026-06-15 (from `docs/archive/2026-06-15-plans/PLAN-jail-networking-v2.md`)  
**Status:** Active specification  
**Тема:** Переход от ip4=inherit на VNET (virtualised network stack) для per-jail сетевой изоляции

**Target:** Chimp v0.2 (Banana Pi aarch64, real hardware)
**See also:**
- `PLAN-jail-prototype.md` — current ip4=inherit jail model (v0.1.x Squirrel)
- `docs/specs/SPEC_jpk_descriptor_v1.md` — .jpk format (declares network policy per jail)
- `docs/specs/SPEC_zenoh_security.md` — Zenoh mTLS over VNET epair
- `ROADMAP.md` — Q3 stream C (jail model)

---

## 1. Текущий подход (ip4=inherit + PF)

| Аспект | Описание |
|--------|---------|
| **Модель** | Jail разделяет сетевой стек хоста |
| ip4=inherit | Видит все интерфейсы, общие маршруты, общий PF |
| ip4=disable | Полная блокировка сети |
| Изоляция | Слабая: jail видит друг друга на сетевом уровне |
| Видимость | Соседний jail по-прежнему доступен на localhost |
| Фильтрация | PF правила на уровне хоста (асимметричная) |

**Проблемы текущего подхода:**
- Два jail не могут занимать один порт (appA:8080 и appB:8080 конфликтуют)
- Нет полной сетевой изоляции
- Сложнее отследить трафик per-jail
- VPN/split-tunnel нельзя настроить per-jail

---

## 2. VNET (Virtual Network Stack)

### Что такое VNET?

VNET — механизм FreeBSD 12+, выделяющий каждому jail **свой собственный сетевой стек**:
- Собственный lo0 (loopback)
- Собственные интерфейсы (epair — pairwise vlan)
- Собственные маршруты и таблицы ARP
- Собственный PF firewall контекст

### Сравнение моделей

| Критерий | ip4=inherit | ip4=disable | VNET jail |
|----------|-----------|-----------|-----------|
| **Сетевой стек** | Разделён с хостом | Нет сети | Изолированный |
| **Видит других jail** | Да (localhost) | — | Нет (мост только через bridge) |
| **Собственный IP** | Нет | — | Да (10.0.N.M/24) |
| **Собственный лo0** | Нет | — | Да (127.0.0.1) |
| **Производительность** | Отличная | — | 1-3% overhead |
| **Сложность** | Низкая | — | Средняя |
| **Два jail на :80** | Конфликт | — | Возможно (разные IPs) |

---

## 3. VNET конфигурация

### 3.1 jail.conf (VNET jail)

```sh
appBrowser {
    # Базовые параметры
    host.hostname = appbrowser.local;
    path = /opt/proto/jails/appBrowser;
    
    # VNET: виртуальный сетевой стек
    vnet;
    vnet.interface = "epair0b";
    
    # IP-адрес и маршрут
    ip4.addr = "10.0.1.2/24";
    ip4.routing;
    defaultrouter = "10.0.1.1";
    
    # IPC
    exec.start = "/etc/rc";
    exec.stop  = "/etc/rc.shutdown";
}

appVideo {
    host.hostname = appvideo.local;
    path = /opt/proto/jails/appVideo;
    
    vnet;
    vnet.interface = "epair1b";
    ip4.addr = "10.0.2.2/24";
    ip4.routing;
    defaultrouter = "10.0.2.1";
    
    exec.start = "/etc/rc";
    exec.stop  = "/etc/rc.shutdown";
}
```

### 3.2 Хост-сторона: эпаир и бридж

```bash
#!/bin/sh
# infra/scripts/vnet-setup.sh

# 1. Создать epair0 (пара интерфейсов: a/b)
ifconfig epair0 create

# 2. Создать bridge0, добавить epair0a
ifconfig bridge0 create
ifconfig bridge0 addm epair0a

# 3. Установить IP хоста на bridge0
ifconfig bridge0 inet 10.0.1.1/24

# То же для epair1
ifconfig epair1 create
ifconfig bridge1 create
ifconfig bridge1 addm epair1a
ifconfig bridge1 inet 10.0.2.1/24

# 4. Поднять все интерфейсы
ifconfig epair0a up
ifconfig epair0b up
ifconfig bridge0 up
ifconfig bridge1 up

# 5. Включить IP forwarding (если нужна маршрутизация между jails)
sysctl net.inet.ip.forwarding=1
```

### 3.3 PF rules для VNET

```
# /etc/pf.conf (хост)

# Соответствие IP адреса -> приложение
table <appBrowser> { 10.0.1.2 }
table <appVideo>   { 10.0.2.2 }

# За-NAT трафик из jails наружу
nat on em0 from 10.0.0.0/16 -> (em0)

# Блокировать трафик между jails по умолчанию
block quick from <appBrowser> to <appVideo>
block quick from <appVideo> to <appBrowser>

# Разрешить исходящий трафик из jails
pass out from 10.0.0.0/16

# Разрешить входящий на конкретные порты
pass in on bridge0 proto tcp to 10.0.1.2 port 8080
pass in on bridge1 proto tcp to 10.0.2.2 port 8081
```

---

## 4. Сценарии использования VNET

### Сценарий A: Два приложения на одинаковом порту
```
appA:8080 (10.0.1.2:8080)  ✓ Работает
appB:8080 (10.0.2.2:8080)  ✓ Работает (разные IPs)
```
В текущем подходе (ip4=inherit) — **конфликт**, нужно использовать разные порты.

### Сценарий B: Сеть между jails заблокирована
```
appBrowser (10.0.1.2) ──X─→ appVideo (10.0.2.2)
```
Благодаря отдельным стекам и PF правилам, межъячеевый трафик блокирован по умолчанию.

### Сценарий C: Split-tunnel VPN per-jail
```
Хост: основной VPN
appA: своя VPN через отдельный epair
appB: без VPN
```
Каждый jail может иметь свой стек маршрутизации.

---

## 5. Миграция: от ip4=inherit к VNET

### Этап 1: Подготовка (Week 1)

- [ ] Написать `infra/scripts/vnet-setup.sh` (создание epair, bridge)
- [ ] Написать `infra/scripts/vnet-cleanup.sh` (teardown)
- [ ] Добавить targets в Makefile: `make vnet-setup`, `make vnet-cleanup`
- [ ] Тестировать на dev-VM (single jail appBrowser + VNET)
- [ ] Проверить PF rules, NAT

**Пример Makefile:**
```makefile
vnet-setup:
	su -m root -c 'sh infra/scripts/vnet-setup.sh'

vnet-cleanup:
	su -m root -c 'sh infra/scripts/vnet-cleanup.sh'

jail-setup: vnet-setup
	su -m root -c 'jailmgr.sh create'
```

### Этап 2: Deployment appBrowser (Week 2)

- [ ] Обновить `jail.conf`: добавить `vnet;` + `epair0b` для appBrowser
- [ ] Обновить IP-адрес: `ip4.addr = "10.0.1.2/24";`
- [ ] Перестартовать jail: `make jail-teardown && make jail-setup`
- [ ] Проверить SSH на 2222 (port forward всё ещё работает)
- [ ] Проверить внутренний IP: `freebsd@localhost:2222 $ ifconfig` → `10.0.1.2`

### Этап 3: Deployment appVideo + изоляция (Week 3)

- [ ] Добавить epair1, bridge1 для appVideo
- [ ] Обновить `jail.conf` для appVideo VNET
- [ ] Обновить PF rules: блокировать межъячеевый трафик, разрешить нужные порты
- [ ] Интеграционный тест: `appBrowser` не видит `appVideo` на сетевом уровне
- [ ] Тест на производительность: latency, throughput в jails

### Этап 4: Документирование (Week 4)

- [ ] Добавить troubleshooting в CLAUDE.md
- [ ] Обновить архитектурную диаграмму в CLAUDE.md
- [ ] Написать guide для per-app сетевой политики (PF rules)

---

## 6. Troubleshooting VNET

| Проблема | Признак | Решение |
|----------|---------|---------|
| Jail не стартует после vnet; | `jexec appA` fails | `ifconfig epair0 up`, проверить vnet.interface в jail.conf |
| Нет интернета в jail | ping 8.8.8.8 fails | Проверить NAT в PF; `sysctl net.inet.ip.forwarding` |
| epair0b не видна в jail | `ifconfig` пусто | jail.conf: правильное имя `epair0b` и порядок boot |
| DNS не работает в jail | `nslookup` fails | Скопировать `/etc/resolv.conf` в jail, или использовать resolver на мосту |
| Два jail видят друг друга | `ping 10.0.2.2` из jail 1 | Проверить PF: должна быть `block quick` между таблицами |

---

## 7. Метрики миграции

| Метрика | Текущий (ip4=inherit) | VNET | Тест |
|---------|----------------------|------|------|
| Время boot jail | ~2 сек | ~2.5 сек | `time jexec appA id` |
| Latency to host | <1 ms | ~1-2 ms | ping 10.0.1.1 в jail |
| Пропускная способность | >900 Mbps | ~850 Mbps | iperf appA → host |
| Память на стек | Разделена | +~8 MB/jail | `vmstat` в jail |

**Вывод:** Overhead VNET приемлем (<5%) для улучшения изоляции.

---

## 8. Риски и смягчение

| Риск | Смягчение |
|------|-----------|
| PF rules слишком сложные | Начать с простых правил (блокировка + whitelist), тестировать поэтапно |
| epair/bridge нестабильны | Регулярный перезапуск jails, мониторинг интерфейсов |
| DNS не работает | Прокинуть resolver на мост через /etc/resolv.conf или dnsproxy |
| NAT конфликты | Использовать уникальные subnet для каждого контекста (10.0.1.0, 10.0.2.0, ...) |

---

## 9. Решение: когда переходить на VNET?

### Переходить СЕЙЧАС, если:
- ✓ Нужно два приложения на одинаковом порту
- ✓ Нужна максимальная сетевая изоляция по требованиям безопасности
- ✓ Планируется split-tunnel VPN per-jail

### Подождать, если:
- Текущий ip4=inherit + PF достаточен для MVP
- Нет требований к полной изоляции сети
- Команда устала от чейнджей

**Рекомендация для bsdOS:** Начать с этапа 1-2 (Week 1-2), если одобрен в roadmap.

---

## 10. Références

- FreeBSD Handbook § 14.4.2 Virtual Network Stacks
- PF User's Guide: https://www.openbsd.org/faq/pf/
- jail(8) man page: `man jail` (vnet, ip4.addr)
- epair(4): Virtual NIC pair device
