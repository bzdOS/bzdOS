# План: разнести `/srv/bsdos` по хостам (workstation / dev-vm / myvm)

**Статус:** выполнен частично (2026-10-01): исходники разнесены, диски VM и
прод-юниты buildhost ещё в папке. Что сделано — §0; ниже план в исходной редакции
с пометками по этапам. Составлен 2026-10-01.
**Правило:** каждая часть живёт на том хосте, где она **исполняется**. buildhost
остаётся гипервизором (единственный KVM-хост), но перестаёт быть местом, где
лежат код, сборка и секреты.

---

## 0. Выполнено 2026-10-01

Каждый вынос: архив на buildhost в `/mnt/storage/backups/` (рядом `.sha256`),
потом копия на целевой хост, потом удаление оригинала из `/srv/bsdos`.

| Что | Куда | Архив на buildhost |
|---|---|---|
| вся история `/srv/bsdos` (`git bundle`, HEAD a8f73f9; clone + `fsck` чистые) + незакоммиченное как `uncommitted.diff` | workstation `/srv/bsdos-archive/` | — |
| часть платы: `hal/*` (кроме `darling-freebsd`), `sys-daemon-zig`, `mali-uio`, `infra/u-boot`, `bsdos-core`, `bsdos-pkgd`, `bsdos-run`, `lifecycled`, `jpk-*`, `guest-agent`, `wayland-tunnel`, `ui*`, сервисы, `proto`, приватность, `artefacts/bsdos-chimp-*.img.gz`, chimp-diag | workstation `/srv/board-from-buildhost/` | `bsdOS-board-20261001-1328.tar.gz` |
| `hal/darling-freebsd` (bundle по каждому сабмодулю) | workstation `/srv/bsdos-archive/darling-freebsd/` | `darling-freebsd-bundle-20261001-1428.tar.gz` |
| `/opt/mrgd` (рабочая копия buildhost) | workstation `/srv/bsdos-archive/mrgd-buildhost/` | `mrgd-buildhost-bundle-20261001-1435.tar.gz` |
| `couplingd`, `hubd-queue-repl`, `ipa-runtime`, `zenoh-util-freebsd`, корневые `Cargo.toml`/`Cargo.lock` (без `target/`) | dev-vm `/opt/bsdos-src/` | `bsdOS-step1-20261001-1436.tar.gz` |

**Потеря и восстановление.** Первый bundle `darling-freebsd` делался
`git bundle --all` — сабмодули в него не вошли, и 3 коммита сабмодулей
(cocotron 2daffffed067, darlingserver e3963cf76ad8, foundation 4ee4a89251d2)
пропали вместе с оригиналом. Их восстановили из рабочей копии на dev-vm (ветка
`salvage-0826`) и влили в `pr-arm64`. Инструмент выноса исправлен: теперь он
делает bundle каждого сабмодуля отдельно.

**Шара `/mnt/bsdos` на dev-vm** умерла около 01:50 и вешала git в госте
(`safe.directory` указывал на мёртвый путь). В госте `bsdos_virtiofs_enable="NO"`,
строка `safe.directory` убрана. `<filesystem>` в XML домена остаётся (этап 6),
rc `guest-agent` в госте всё ещё ссылается на `/mnt/bsdos`.

**D2 решён в сторону (б):** нативная сборка omp под FreeBSD x64 на dev-vm
работает, агенты-головы переносят себя на dev-vm сами. dev-vm расширен до
20 vCPU / 32G, на `/` 30G свободно (было 14G).

**Не тронуто:** диски VM, `seed.iso`, `freebsd*.qcow2.xz` (этап 2, D4);
`infra/` (мост hubd↔Matrix и бэкапы — этап 1/3), `artefacts/` (кроме
chimp-образов), `docs/`, `mac-companion/`, `target/`. 580 удалений от выноса
**не закоммичены** — дерево `git status` показывает их как ` D`.

Сейчас: `/srv/bsdos` = 225G, корневая ФС buildhost 90% (87G свободно — меньше,
чем 177G при инвентаризации; архивы выноса лежат на другом диске,
`/mnt/storage` 91%, причина роста не выяснена). Почти весь объём папки — диски
VM, поэтому до этапа 2 вынос кода место не освобождает.

---

## 1. Что сегодня держит папку (снято 2026-10-01)

`/srv/bsdos` = 226G, диск buildhost 80% (177G свободно). Это не просто репозиторий,
а четыре разные роли в одной папке:

| Роль | Что | Кто зависит |
|---|---|---|
| **Хранилище дисков VM** | `freebsd-x86-15.1.qcow2` 155G, `myvm.qcow2` 46G, `freebsd14.qcow2` 9.4G, `seed.iso` | libvirt `bsdos-x86` (dev-vm), `myvm` (myvm, **прод**), `bsdos-dev` (выкл.) |
| **Общая ФС гостей** | вся папка → virtiofs/9p `/mnt/bsdos` в dev-vm и myvm | сборка на dev-vm, стейджинг бинарников dev-vm→myvm (`artefacts/myvm-bin/`) |
| **Рабочий каталог прод-юнитов buildhost** | `bsdos-key`, `infra/scripts/hubd-matrix-bridge.py`, `artefacts/*.env`, serial-лог libvirt | 5 юнитов: `mesh-tunnel-dev-vm/myvm`, `matrix-hs`, `hubd-matrix-bridge`, `mrgd-store-backup` + живые ssh-туннели |
| **Исходники + git** | ~15G с `target/` 5.2G и `hal/darling-freebsd` 4G | все агенты (cwd сессий Claude = `/srv/bsdos`) |

Масштаб правок путей: `/mnt/bsdos` — 158 вхождений в 53 файлах;
`/srv/bsdos` — 705 вхождений в 152 файлах (из них 44 файла — Makefile/скрипты/rc.d/юниты,
остальное — доки).

**Блокеры, найденные при инвентаризации:**
- **У репозитория нет remote.** `git remote -v` пуст: вся история существует в
  одном экземпляре на buildhost. Всё остальное можно делать только после этого пункта.
  *(01.10: remote по-прежнему нет; офлайн-копия истории — bundle на workstation, §0.)*
- **У dev-vm 14G свободно (90%)** — полный checkout + `target/` + darling-сборка туда не влезут без расширения диска.
  *(01.10: dev-vm расширен, 30G свободно.)*
- Рабочее дерево ещё грязное (см. §5). *(01.10: плюс 580 незакоммиченных удалений от выноса.)*

---

## 2. Целевое размещение

| Часть | Сейчас | Куда | Почему там |
|---|---|---|---|
| **Канонический git** | только buildhost | remote (решение **D1**) + checkout'ы на хостах | единственная копия истории = риск; хостам нужен общий источник |
| Исходники + сборка (Rust, Zig, darling, ports, `bpi-image.sh`, образы Squirrel/Chimp) | buildhost, собирается на dev-vm через шару | **dev-vm**: локальный checkout, локальный `target/` | CLAUDE.md: «сборка только на dev-vm»; `bpi-image.sh` требует FreeBSD (`mdconfig`, `mkimg`) |
| Бинарники рантайма | `artefacts/myvm-bin/` через шару | **myvm**: только бинарники, без checkout'а | myvm = runtime only |
| Путь стейджинга dev-vm→myvm | через шару репо | **отдельная** маленькая шара `stage` (решение **D3**) | развязать деплой и репо |
| Chimp: U-Boot, FEL-утилита, готовые образы, скрипты прошивки | `infra/u-boot/`, `artefacts/bsdos-chimp-*.img.gz` | **workstation** (к плате) | плата подключена к workstation; `sunxi-fel-fit-capable` — это x86 Linux ELF |
| Микроядро EL2 | уже на workstation (`<microkernel-repo>/`) | без изменений | — |
| `mac-companion/` | в workspace | остаётся в репо, checkout на Mac | собирается и запускается на Mac |
| Диски VM + `seed.iso` | внутри репо | **buildhost** `/var/lib/libvirt/images/` | та же ФС (`nvme0n1p5`) → `mv` = мгновенный rename, копирования нет |
| Serial-лог `bsdos-x86` | `artefacts/logs/serial-x86.log` | **buildhost** `/var/log/libvirt/qemu/` | libvirt пишет его сам |
| Прод-юниты buildhost + их скрипты | `infra/…` прямо из репо | **buildhost** `/opt/bsdos-ops/` (ставятся из репо скриптом `install`) | юниты не должны исполнять файлы из рабочей копии (прецедент 2026-07-29: `cargo clean` снёс бинарь юнита) |
| Секреты: `bsdos-key`, `artefacts/*.env` | в репо (под `.gitignore`) | **buildhost** `/etc/bsdos/` (0600) | секреты вне рабочей копии |

---

## 3. Решения, которые принимаете вы

- **D1 — где канонический remote.** Факт (gh, 2026-10-01): в org `bzdOS` уже
  есть **публичный** `bzdOS/bzdOS` — это отобранный релизный снимок v0.1.3
  (3 коммита, 289 KB), **не** история разработки, пушить туда монорепо нельзя.
  Компоненты уже вынесены отдельно: `bsdos-hal`, `WLTunnel`, `metal-viewer`,
  `WLStream`, `jailrun`, `lima-freebsd`, `bzdk` (гипервизор), `mrgd`, `hubd`,
  `darling*`, `zenoh`. Приватные репозитории org поддерживает (`BareChat`).
  Значит, вариант (а) — **новый приватный** репо (напр. `bzdOS/bsdos-dev`), и
  перед первым push прогнать по истории сканер секретов (gitleaks/trufflehog):
  ключи сейчас под `.gitignore`, но в 994 коммитах могли проскочить раньше.
  (а) приватный `github.com/bzdOS/bsdos-dev`:
  доступен со всех хостов, включая Mac за ТСПУ через obfs? — **проверить**;
  (б) bare-репо на workstation; (в) bare-репо на buildhost + зеркало. Рекомендация:
  (а) + `git bundle` на workstation как офлайн-бэкап. **Рекомендация пока не
  проверена**: неизвестно, достаёт ли dev-vm до GitHub (раз `wlstream` тянется с
  github.com, то скорее да).
- **D2 — где работают агенты.** Сегодня все сессии Claude запускаются на buildhost
  с cwd `/srv/bsdos` (память, хуки, hubd `cwd`-резолв — всё завязано на этот
  путь). Варианты: (а) на buildhost остаётся **лёгкий** checkout только для правки
  кода (без `target/`, без дисков, без секретов), push → dev-vm pull+build — меньше
  всего ломает; (б) агенты переезжают на dev-vm — Claude Code на FreeBSD не
  проверен, это отдельный проект. Рекомендация: (а). Честно: с (а) «убрать
  папку» означает «убрать из неё всё, кроме кода».
  **Решено 01.10: (б)** — агенты на dev-vm через нативную сборку omp (§0).
- **D3 — транспорт стейджинга dev-vm→myvm.** (а) отдельная virtiofs-шара
  `/srv/bsdos-stage` на buildhost в обе VM — минимум изменений, логика
  `deploy-bsdos-myvm.sh` та же; (б) pkg-репо на dev-vm → `pkg add` на myvm (уже
  используется для electron42). Рекомендация: сначала (а), потом (б).
- **D4 — что выбросить:** `*.qcow2.xz` ×4 (2.5G, исходные образы от 2026-03…06),
  `freebsd14.qcow2` + домен `bsdos-dev` (выключен, «ДРУГАЯ VM, не сборочная»),
  `artefacts/matrix-hs.pre-todevice-fix` (284M, старый бинарь), 110 файлов в
  `queues/`. Без вашего «да» ничего из этого не удаляется.

---

## 4. Этапы (по возрастанию риска; у каждого есть go/no-go)

**Этап 0 — remote и бэкап (без простоя).**
Привести дерево в порядок (§5) → `git bundle create` → на workstation → создать
remote (D1) → `git push --all --tags`.
*Go:* `git clone` с remote на dev-vm даёт тот же `HEAD`, `git fsck` чистый.
*01.10: сделан только бэкап (bundle на workstation, clone + fsck чистые). Remote не создан.*

**Этап 1 — вынести прод-юниты buildhost из репо (короткие рестарты).**
`bsdos-key` и `*.env` → `/etc/bsdos/`; `hubd-matrix-bridge.py`,
`backup-mesh-stores.sh` и т.п. → `/opt/bsdos-ops/` через новый
`infra/scripts/install-buildhost-ops.sh`; поправить `EnvironmentFile=`/`ExecStart=`
в 5 юнитах (`infra/systemd/` + `/etc/systemd/system/`). Рестартовать **по
одному**, `mesh-tunnel-*` — последними: они держат связность dev-vm/myvm.
*Go:* все 5 active, `ps` не показывает ни одного процесса с `/srv/bsdos`
(кроме QEMU — это этап 2), мост постит в Matrix.

**Этап 2 — вынести диски VM из репо (окно простоя, особенно для myvm).**
Порядок: `bsdos-dev` (выкл.) → `bsdos-x86` → `myvm`. Для каждого домена:
`virsh shutdown` (**не** destroy — ломает UFS, см. память) → `mv` в
`/var/lib/libvirt/images/` (та же ФС, мгновенно) → `virsh edit` путей
disk/cdrom/serial-log → проверить метку AppArmor/`virt-aa-helper` для нового
пути → `virsh start`. Шара `/srv/bsdos` пока остаётся.
*Go:* обе VM up, `bsdos.agent` = connected, на myvm AUTOSTREAM поднялся, dev-vm:443 слушает.
*Откат:* `mv` обратно + прежний XML (сохранить `virsh dumpxml` до правки).

**Этап 3 — dev-vm становится домом сборки.**
Расширить диск dev-vm (`virsh blockresize` + `gpart resize` + `growfs`, как
2026-07-04; +60G из 177G свободных на buildhost) → `git clone` в локальный путь
(предлагаю `/build/bsdOS`) → сборка оттуда, `target/` локальный (заодно уходит
класс wedge'ей p9fs/virtiofs на сборке). Поправить 44 исполняемых файла с
`/mnt/bsdos` и `/srv/bsdos` (Makefile, `infra/scripts`, `rc.d`) на переменную
`BSDOS_ROOT` вместо хардкода.
*Go:* `make build-agent` и cargo-workspace собираются из `/build/bsdOS` при
отмонтированной `/mnt/bsdos`.
*01.10: начат иначе — диск dev-vm расширен, Rust-исходники лежат в
`/opt/bsdos-src` (не `/build/bsdOS`) без git-checkout'а; шара в госте
выключена. Сборка оттуда и правка 44 файлов на `BSDOS_ROOT` не проверены.*

**Этап 4 — стейджинг dev-vm→myvm без шары репо (D3).**
Завести `stage`-шару (или pkg-репо), перевести `deploy-bsdos-myvm.sh --all`.
*Go:* полный деплой на myvm проходит, в `mount` на myvm нет шары репо.

**Этап 5 — Chimp-артефакты на workstation.**
`infra/u-boot/bananapi-m64/*`, образы `bsdos-chimp-*.img.gz` и скрипты прошивки
(FEL/dd) → каталог на workstation; источник образов = сборка на dev-vm, доставка
dev-vm→workstation (транспорт решить вместе с D1).
*Go:* прошивка платы проходит с workstation без обращения к buildhost.
*01.10: перенос сделан (`/srv/board-from-buildhost/` на workstation, с `infra/u-boot` и
chimp-образами). Прошивка с workstation без buildhost не проверялась.*

**Этап 6 — снять шару репо с VM и разгрузить buildhost.**
Удалить `<filesystem>` `/srv/bsdos` из XML `bsdos-x86` и `myvm`, убрать
`bsdos_virtiofs` и 9p-строку из fstab гостей (**аккуратно**: 9p-строка в fstab
критична для загрузки, см. `README-x86-kvm.md`). На buildhost остаётся лёгкий
checkout (D2-а): удалить `target/`, `artefacts/` и лишнее из D4.
*Go:* обе VM грузятся без шары, в `/srv/bsdos` только код (≲10G). Реально
освобождается на buildhost немного: `target/` 5.2G + `artefacts/` 2.3G + то, что
одобрите в D4. Диски VM (210G) просто переезжают внутри той же ФС.

**Этап 7 — доки и память.**
CLAUDE.md («Истина кода», «Guest paths», «Deploy pipeline», топология),
`docs/DEV-VM.md`, `README-x86-kvm.md`, записи памяти (`dev-vm-virtiofs-fix`,
`buildhost-host-disk`, `vm-9p-reset-recovery`) — переписать под новую модель.
Хвост из 705 упоминаний `/srv/bsdos` в доках чистить `git grep` по категориям,
не вслепую через sed.

---

## 5. Предусловия — хвосты уборки 2026-10-01

Сделано: 5 коммитов (рантайм-мусор, доки Matrix, mesh/mrgd-юниты, dev-VM-инфра,
GPT-фикс `bpi-image`). Осталось до этапа 0:
- `lifecycled/src/main.rs` + `DESIGN-devfs-ruleset4.md` — ждут `cargo check` на dev-vm (не завершился за 30+ мин — выяснить почему).
- Удаление `matrix-hs/` + `Cargo.toml`/`Cargo.lock` — тот же `cargo check`.
- Указатель субмодуля `hal/darling-freebsd` (7d45407 → 951bcfb; внутри субмодуля есть свои незакоммиченные правки). *01.10: каталог вынесен (§0), но gitlink (7d45407) остаётся в индексе и в `git status` не виден — убрать отдельно (`git rm --cached`) вместе с коммитом удалений.*
- *01.10:* закоммитить 580 удалений от выноса — после сверки, что каждый удалённый каталог есть в архиве и на целевом хосте.
- 50 сиротских веток `worktree-agent-*`: все коммиты уже есть в master по patch-id; удалить.
- Внутри `queues/` остались 2 отслеживаемых файла (`README.md`, `smoketest.queue.md`).

## 6. Не проверено

- Доступ dev-vm/myvm/workstation к GitHub (D1) и Mac к remote через ТСПУ.
- Свободное место на workstation и myvm.
- Профиль AppArmor libvirt для `/var/lib/libvirt/images` — дефолтный, но при
  переносе дисков проверить `virt-aa-helper`.
- Есть ли на myvm что-то, кроме `myvm-bin/`, что читает `/mnt/bsdos` (grep rc.d на myvm).
