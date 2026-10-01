# RUNBOOK — myvm: virtio-serial канал для bsdos_agent (паритет с dev-vm)

> **Задача a hub task** (bsdos). Цель: дать prod-VM `myvm` ($BSDOS_MYVM_IP, libvirt-домен
> `myvm`, runs_on `buildhost`) тот же virtio-serial канал для агента, что есть на dev-VM
> `bsdos-x86` («dev-vm»), — «agent-паритет с dev-vm». Подготовка only; исполнение — кнопка
> OWNER (живой прод).
>
> Автор: sonnet-bsdos · 2026-07-15 · claim `3445de73` · область: этот файл.

## 0. Контракт паритета (что значит «готово»)

| | dev-vm (эталон, live) | myvm (цель) |
|---|---|---|
| virtio-serial controller | `index='0'` ✅ | **нет** → добавить |
| agent channel | `<channel type='unix' name='bsdos.agent'>` port 2 ✅ | **нет** → добавить |
| host socket | `/tmp/bsdos-agent-vport-x86.sock` ✅ (live с 2026-07-06) | `/tmp/bsdos-agent-vport-myvm.sock` (новый, свой) |
| guest нода | `/dev/ttyV0.2` ✅ | должна стать `/dev/ttyV0.2` |
| guest rc.d `bsdos_agent` | enable, chardev `/dev/ttyV0.2` ✅ | уже enable, ждёт `/dev/ttyV0.2` (verified, self-skip пока устройства нет) |
| 9p `/mnt/bsdos` | ✅ | ✅ уже смонтирован (fs0 в XML myvm) |

**Транспорт — НЕ vsock.** AF_VSOCK нигде в XML dev-vm нет (см. `docs/archive/2026-06-15-plans/`:
vsock отложен, нужен custom kernel; virtio-console — в base FreeBSD, выбрали его).

**Ключевой механизм портов:** libvirt назначает порты virtio-serial **в порядке объявления**
каналов. На dev-vm `spicevmc` объявлен первым → port 1 (`/dev/ttyV0.1`), `bsdos.agent` вторым →
**port 2 (`/dev/ttyV0.2`)**. rc.d `bsdos_agent` по умолчанию открывает именно `/dev/ttyV0.2`
(`infra/rc.d/bsdos_agent:20`, `:64` — иначе self-skip). ⇒ Чтобы НЕ трогать гостя, myvm должен
повторить тот же порядок объявлений (spicevmc первым как «заглушка» порта 1).

## 1. XML-патч для myvm

Вставить блок **внутрь `<devices>`** (например, сразу после закрывающего тега `</console>`
isa-serial, перед `<input ...>`). Порядок объявлений сохранять строго:

```xml
    <!-- ==== virtio-serial: agent channel (agent-паритет с bsdos-x86/dev-vm) ==== -->
    <!-- Контроллер. PCI-адрес НЕ задаём — libvirt сам выделит свободный слот на bus 0
         (заняты: 01.1 ide, 02 fs0, 03 net0, 04.x usb, 05 disk, 06 balloon, 07 fs1). -->
    <controller type='virtio-serial' index='0'/>

    <!-- port 1 — «заглушка», занимает 1-й порт, чтобы agent уехал на port 2 (/dev/ttyV0.2).
         state будет disconnected (spice-дисплея на prod нет) — это нормально и идентично dev-vm.
         НЕ УДАЛЯТЬ: без него agent получит port 1 → /dev/ttyV0.1 → rc.d self-skip. -->
    <channel type='spicevmc'>
      <target type='virtio' name='com.redhat.spice.0'/>
    </channel>

    <!-- port 2 — bsdOS agent. Host-сторона: unix-socket /tmp/bsdos-agent-vport-myvm.sock
         (суффикс -myvm, чтобы не collide с -x86 от dev-vm на том же хосте). -->
    <channel type='unix'>
      <source mode='bind' path='/tmp/bsdos-agent-vport-myvm.sock'/>
      <target type='virtio' name='bsdos.agent'/>
    </channel>
```

Это **точное зеркало** `infra/vm-templates/bsdos-x86-kvm.xml:74-86` (канонический шаблон dev-vm),
отличается только `path` сокета (`-myvm` вместо `-x86`).

### Альтернатива B (более «чистая», без spicevmc) — НЕ рекомендуется для первого применения
Можно не ставить spicevmc, а явно пришпилить agent к port 2 адресом:
```xml
    <controller type='virtio-serial' index='0'/>
    <channel type='unix'>
      <source mode='bind' path='/tmp/bsdos-agent-vport-myvm.sock'/>
      <target type='virtio' name='bsdos.agent'/>
      <address type='virtio-serial' controller='0' bus='0' port='2'/>
    </channel>
```
Меньше «мёртвого» канала, но этот вариант менее battle-tested (проверять, что гость реально
создаёт `/dev/ttyV0.2` при отсутствии port 1). **Для первого применения на прод — брать
вариант A** (точное зеркало dev-vm). B — как возможное упрощение после того, как A устоится.

## 2. Pre-flight (read-only, до окна) — выполнить ПЕРЕД изменениями

```sh
# 0. myvm жив и это он
virsh dominfo myvm | egrep 'Name|State|CPU\(s\)|Memory'
virsh domiflist myvm                                   # MAC 52:54:00:fa:64:a2, br0

# 1. Снимок текущего XML (он же — база отката)
virsh dumpxml myvm > /srv/bsdos/artefacts/myvm-pre-virtio-serial.$(date -u +%Y%m%dT%H%M%SZ).xml
#    Проверить, что virtio-serial там ДЕЙСТВИТЕЛЬНО отсутствует (должен быть пусто):
grep -iE 'virtio-serial|bsdos.agent|spicevmc' /srv/bsdos/artefacts/myvm-pre-virtio-serial.*.xml

# 2. Целевой host-сокет ещё не существует (если существует — удалить/переименовать, иначе define упадёт):
ls -la /tmp/bsdos-agent-vport-myvm.sock 2>/dev/null   # expect: No such file or directory

# 3. На хосте есть socat (нужен для post-check): command -v socat   # 1.8.0.0 — подтверждено

# 4. (опц, через существующий доступ в myvm) сверить guest-готовность:
#    sysrc -R bsdos_agent_enable bsdos_agent_chardev   # expect: YES / /dev/ttyV0.2
#    mount | grep bsdos                                # 9p /mnt/bsdos mounted
```

## 3. Окно и даунтайм

**Что упадёт на время рестарта myvm** (по `hub_resource_get myvm` + #145): ClickHouse,
Caddy (TLS: example.net / board.example.net / mcp.example.net / app.kolkhoz.io / homeserver.example),
matrix-hs:8448 (homeserver.example), bsdos-core:7447, hubd serve/mcp, mosquitto, saas-core,
TG-боты (vyvozavr, empathic-talk), bsdos-lifecycled.

**Оценка простоя:**

| Этап | Типично | Худшее |
|---|---|---|
| `virsh shutdown myvm` (ACPI graceful) | 20–40 s | ~90 s (ClickHouse закрывает WAL) |
| `virsh define`/`attach-device --config` (offline-правка) | <2 s | <2 s |
| `virsh start myvm` (EFI + FreeBSD boot + rc.d) | 20–40 s | ~60 s |
| Поднятие сервисов до readiness (ClickHouse — длинное плечо) | 30–60 s | ~90 s (WAL replay) |
| **Итого недоступность** | **~2–4 мин** | **~5 мин** |

**Длинное плечо оба направления — ClickHouse.** Остальные сервисы поднимаются за секунды.
matrix-clients (Element) покажут disconnect на ~15–30 s и переподключатся; example.net/MCP и
TG-боты будут unreachable на всё окно.

**Риск:** если `virsh shutdown` висит (FreeBSD ACPI изредка не отвечает) — fallback
`virsh destroy myvm` (аналог выдёргивания питания). ClickHouse crash-safe (WAL replay), но
`destroy` увеличивает время старта и это — последний resort. закладывать +1–2 мин.

**Предлагаемое окно:** low-traffic, напр. **02:00–04:00 UTC** (или локальное low-traffic на
усмотрение OWNER). Окончательный выбор — за OWNER.

## 4. Применение (Method A — dumpxml/define, как описано в задаче)

Выполнять ТОЛЬКО в согласованное окно, с терминала на buildhost. НЕ прерывать посередине.

```sh
set -euo pipefail
DOM=myvm
TS=$(date -u +%Y%m%dT%H%M%SZ)
BK=/srv/bsdos/artefacts/${DOM}-pre-virtio-serial.${TS}.xml

# 1) Backup (он же откат)
virsh dumpxml ${DOM} > "${BK}"
grep -iE 'virtio-serial|bsdos.agent' "${BK}" && { echo "ABORT: virtio-serial уже есть?!"; exit 1; }

# 2) Подготовить патченный XML: вставить блок из §1 после </console>.
#    Рекомендуется скриптом (xmllint/python), чтобы не руками. Пример (python3, без зависимостей):
python3 - <<PY
import re, sys
src = open("${BK}").read()
pat = re.compile(r'(</console>\s*)', re.S)
ins = open('/srv/bsdos/infra/docs/myvm-virtio-serial-block.xml').read()  # блок §1 как отдельный файл
assert pat.search(src), 'не нашёл </console>'
assert 'virtio-serial' not in src, 'virtio-serial уже есть — ABORT'
out = pat.sub(r'\1\n' + ins + '\n', src, count=1)
open('/tmp/myvm.patched.xml','w').write(out)
print('patched xml -> /tmp/myvm.patched.xml')
PY

# 3) Сухая проверка синтаксиса (libvirt валидирует без применения):
virsh define /tmp/myvm.patched.xml            # define можно на running-домене? НЕТ см. ниже
#    ВАЖНО: define на running-домене обновит config, но НЕ live. Перезапуск всё равно нужен.
#    Поэтому корректный порядок — сначала shutdown, потом define, потом start (см. далее).

# --- собственно применение ---
virsh shutdown ${DOM}
# ждать выключения (до 120 s), потом проверить:
for i in $(seq 1 60); do
  [ "$(virsh domstate ${DOM})" = "shut off" ] && break
  sleep 2
done
[ "$(virsh domstate ${DOM})" = "shut off" ] || { echo "graceful не вышёл — см. §6 destroy-fallback"; exit 1; }

virsh define /tmp/myvm.patched.xml
virsh start ${DOM}

# 4) Подождать host-сокета (QEMU создаёт его после старта):
for i in $(seq 1 30); do [ -S /tmp/bsdos-agent-vport-myvm.sock ] && break; sleep 1; done
ls -la /tmp/bsdos-agent-vport-myvm.sock
```

> `define` на shut-off домене атомарно заменяет persistent XML. `start` поднимает уже с новым
> устройством. Блок `§1` удобнее держать отдельным файлом
> `infra/docs/myvm-virtio-serial-block.xml` (приложен ниже, §8) — так инъекция детерминирована.

## 5. Method B (альтернатива, меньше ручного XML-редактирования)

`virsh attach-device --config` пишет в persistent config, не трогая live. На running-домене
безопасно; устройство появится после следующего boot. Три вызова (controller + 2 канала):

```sh
virsh attach-device myvm controller-virtio-serial.xml --config     # <controller type='virtio-serial' index='0'/>
virsh attach-device myvm channel-spicevmc.xml      --config     # spicevmc (port 1 заглушка)
virsh attach-device myvm channel-bsdos-agent.xml   --config     # unix bsdos.agent
virsh dumpxml myvm | grep -iE 'virtio-serial|bsdos.agent|spicevmc'   # убедиться, что попало в config
# затем — то же shutdown/start, что в §4 (устройство поедет только после рестарта)
virsh shutdown myvm && ... && virsh start myvm
```
Плюс: не правим 200 строк доменного XML вручную, меньше риск сломать структуру. Оба метода
эквивалентны по результату.

## 6. Post-check (после старта)

```sh
# (a) host: сокет создан
ls -la /tmp/bsdos-agent-vport-myvm.sock            # должен существовать

# (b) libvirt: каналы определены, agent = connected
virsh dumpxml myvm | grep -A1 'bsdos.agent' | grep state          # expect: state='connected'
virsh dumpxml myvm | grep -A1 'com.redhat.spice.0' | grep state   # expect: state='disconnected' (норма)

# (c) echo round-trip через агент (текст-протокол CMD\n / +OK\n):
printf 'PING\n' | socat - UNIX-CONNECT:/tmp/bsdos-agent-vport-myvm.sock
#    expect: +OK bsdos-agent proto=2 jobs=<n>/<cap>   (HELLO/PING по agent-proto-v2)

# (d) в госте (через существующий доступ, например ssh myvm ИЛИ сам канал):
#     ls -l /dev/ttyV0.2                # устройство появилось
#     service bsdos_agent status        # running
#     dmesg | grep -i vtcon             # драйвер привязан
#     sysrc bsdos_agent_chardev         # /dev/ttyV0.2

# (e) остальные сервисы поднялись:
virsh domstate myvm                                   # running
# (на myvm) sockstat -l4 | egrep '7447|8448|9000|443|1883'  ; service clickhouse status
```

**Критерий успеха:** `/dev/ttyV0.2` существует в госте, `bsdos_agent` running, канал
`bsdos.agent` = `connected`, `PING` → `+OK bsdos-agent …`, и все prod-сервисы (ClickHouse,
Caddy, matrix-hs, bsdos-core, hubd) поднялись.

## 7. Откат

Если что-то не так (нет `/dev/ttyV0.2`, канал `disconnected`, прод не поднялся):

```sh
virsh shutdown myvm       # или destroy если висит
virsh define "${BK}"      # восстановить исходный XML из бэкапа §2/§4
virsh start myvm
# прод возвращается в исходное состояние (без virtio-serial); агент остаётся на ssh+scp как было
```
Стоимость отката = то же ~2–4 мин простоя. Бэкап `${BK}` (полный dumpxml до правки) —
единственный источник истины для отката; хранить в `artefacts/`.

## 8. Приложение: блок для инъекции (`infra/docs/myvm-virtio-serial-block.xml`)

Содержимое = ровно блок §1 (controller + spicevmc + unix bsdos.agent, без `<devices>`-обёртки).
Используется Method A (§4) для детерминированной вставки. Создать отдельным файлом.

## Риски / заметки

- **Hotplug НЕ работает** для нового virtio-serial controller (на уже существующем контроллере
  порт можно добавить live — но у myvm контроллера пока нет). ⇒ обязателен полный рестарт. Это и
  есть причина даунтайма.
- **Имя ноды `/dev/ttyV0.2`** держится только пока spicevmc занимает port 1. Удаление spicevmc
  (вариант B) требует перепроверки либо правки `bsdos_agent_chardev` в госте.
- **Коллизия сокетов**: два домена на одном buildhost, суффиксы `-x86` и `-myvm` разводят их.
  direct-QEMU использует `/tmp/bsdos-agent-vport.sock` (без суффикса) — не путать (см. CLAUDE.md).
- **ClickHouse** — длинное плечо даунтайма оба направления; убедиться, что свободное место на
  диске myvm есть (WAL replay на забитом диске = катастрофа; см. урок `docs/DEV-VM.md` про 100% `/`).
- **EFI/OVMF**: myvm грузится через OVMF (`pc-i440fx-noble-v2`); define сохраняет nvram, vars не
  трогаем. После start проверить, что грузится с того же диска.
