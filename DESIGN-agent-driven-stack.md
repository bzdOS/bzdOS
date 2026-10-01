# DESIGN-agent-driven-stack.md — Почему niche стек

**Date:** 2026-06-12
**Status:** Accepted
**Supersedes:** None

---

## Thesis

**bsdOS стек оптимизирован для agent-driven development, а не для human developers.**

Традиционные критерии выбора технологий (community size, job market, Stack Overflow answers) неприменимы, когда код пишут AI-агенты.

---

## Core Principle

> **Агенты пилят — всё решается патчами недостающего.**

Агенты не нуждаются в ecosystem. Агенты нуждаются в:
1. Чётких контрактах (semantic markup)
2. Предсказуемом поведении (no hidden complexity)
3. P2P координации (без central broker)
4. Декларативной конфигурации (не imperative scripting)

---

## Технология → Обоснование

### FreeBSD (не Linux)

| Критерий для агентов | FreeBSD | Linux |
|---|---|---|
| Конфигурация | rc.d — shell scripts, агенты понимают | systemd — unit files, dependencies, targets — сложно |
| Sandbox | Jails — декларативный `jail.conf` | namespaces — root→root possible, security mistakes |
| Package manager | pkg — простой, предсказуемый | apt/dnf — dependency hell, agents путаются |
| Stability | ABI stable между версиями | Breaking changes между distro versions |

**Вывод:** FreeBSD проще для агентов — меньше edge cases, декларативнее.

### Zig (не Rust/C)

| Критерий для агентов | Zig | Rust | C |
|---|---|---|---|
| Memory model | No hidden allocations — агенты не делают memory mistakes | Ownership — agents борются с borrow checker | Segfault, buffer overflow — agents не замечают |
| Comptime | Вычисления на compile time — меньше runtime bugs | Const generics — сложно | Нет |
| C interop | Seamless — agents используют libc напрямую | FFI — verbose | Native |
| Compile time | Быстрый (секунды) | Медленный (минуты) | Быстрый |
| Cross-compile | Built-in — agents собирают под ARM/RISC-V без pain | Cross toolchain — сложно | Cross toolchain — сложно |

**Вывод:** Zig — no surprises, agents не делают subtle bugs.

### Zenoh (не MQTT/HTTP/gRPC)

| Критерий для агентов | Zenoh | MQTT | HTTP | gRPC |
|---|---|---|---|---|
| Topology | P2P — agents не координируют broker | Broker required — single point of failure | Client-server — нужен server | Client-server — нужен server |
| Discovery | Automatic — agents находят друг друга | Manual config | Manual config | Manual config |
| Transport | Multi (UDP, TCP, serial, shared memory) | TCP only | TCP only | TCP only |
| Query/Get | Built-in — agents запрашивают данные у конкретного node | Нет | REST (overkill) | Unary (request/response) |
| Zero-copy | Да — agents не копируют данные | Нет | Нет | Нет |

**Вывод:** Zenoh — agents координируются без central broker, P2P mesh.

### Cap'n Proto (не Protobuf/gRPC)

| Критерий для агентов | Cap'n Proto | Protobuf | gRPC |
|---|---|---|---|
| Parsing | Zero-copy — agents читают прямо из буфера | Parse + copy | Parse + copy |
| Schema | `.capnp` файл — agents читают и понимают контракт | `.proto` — code generation, agents не видят | `.proto` + service definition |
| Code generation | Optional (hand-rolled encoder) | Required — agents не понимают generated code | Required |
| Latency | <1μs per message | ~10μs | ~100μs |
| Boilerplate | Минимум | Много | Много |

**Вывод:** Cap'n Proto — schema-first, agents читают `.capnp` и понимают контракт без codegen.

### Cage/Weston (не Sway/X11)

| Критерий для агентов | Cage/Weston | Sway | X11 |
|---|---|---|---|
| Headless | Да — agents тестируют без GUI | DRM/KMS required — нужен GPU | X server required |
| Complexity | Один app fullscreen | Multi-window tiling — agents тестируют layout | 30 лет legacy — agents путаются |
| Configuration | Простой | i3 config — сложно | xorg.conf — сложно |
| Automation | wl-keepalive, foot — agents запускают | swaymsg — IPC, agents понимают | xdotool — fragile |

**Вывод:** Cage/Weston — agents тестируют headless, без GUI complexity.

### Jails + Capsicum (не Docker/namespaces)

| Критерий для агентов | Jails + Capsicum | Docker | namespaces |
|---|---|---|---|
| Configuration | `jail.conf` — декларативный | Dockerfile + compose.yml — много YAML | Imperative syscalls |
| Security | Capsicum — capability-based, fine-grained | seccomp — blacklist, agents делают mistakes | Root→root possible |
| Overhead | Lightweight — нет daemon | containerd daemon — overhead | Нет daemon, но нет isolation |
| Networking | ip4=inherit/disable — простое | Bridge network — сложно | Host network — нет isolation |

**Вывод:** Jails — декларативные, agents пишут конфиг, не Dockerfile.

### Semantic Markup (не JSDoc/docstrings)

| Критерий для агентов | Semantic Markup | JSDoc | docstrings |
|---|---|---|---|
| Structure | START/END якоря — agents видят блоки | Комментарии — agents парсят текст | Комментарии — agents парсят текст |
| Contracts | purpose/input/output/sideEffects — agents понимают контракт | @param/@returns — agents угадывают | :param/:returns — agents угадывают |
| Validation | `make sema-check` (github.com/bzdOS/sema) — agents проверяют парность | Нет валидации | Нет валидации |
| Machine-readable | Да — agents извлекают контракты | Нет — humans читают | Нет — humans читают |

**Вывод:** Semantic markup — agents читают контракты, не угадывают.

### hubd (не Kubernetes)

| Критерий для агентов | hubd | Kubernetes |
|---|---|---|
| Orchestration | Claims.jsonl — agents координируются через locks | etcd — agents координируются через API |
| Complexity | Один бинарь | etcd + API server + scheduler + kubelet |
| P2P | Zenoh gossip — agents находят друг друга | Central control plane |
| Use case | Multi-agent coordination | Container orchestration |

**Вывод:** hubd — agents координируются через Zenoh, не через K8s API.

---

## Anti-pattern: Mainstream стек для agents

Если бы мы выбрали mainstream стек:

```
Linux + systemd + Docker + K8s + Rust + gRPC + Sway + namespaces + JSDoc
```

**Проблемы для agents:**

1. **systemd** — agents путаются в unit dependencies, targets, sockets
2. **Docker** — agents делают ошибки в Dockerfile (layer caching, ENTRYPOINT vs CMD)
3. **K8s** — agents не понимают YAML nesting (spec.template.spec.containers[0].env[0].value)
4. **Rust** — agents борются с borrow checker, compile time 10+ минут
5. **gRPC** — agents не понимают generated code, много boilerplate
6. **Sway** — agents тестируют GUI, сложно автоматизировать
7. **namespaces** — agents делают security mistakes (root→root)
8. **JSDoc** — agents угадывают контракты из комментариев

**Результат:** agents тратят 80% времени на борьбу со стеком, 20% на actual work.

---

## bsdOS стек для agents

```
FreeBSD + rc.d + Jails + Capsicum + Zig + Cap'n Proto + Zenoh + Cage + Semantic Markup + hubd
```

**Преимущества для agents:**

1. **rc.d** — agents пишут shell scripts, понимают
2. **Jails** — agents пишут `jail.conf`, декларативно
3. **Capsicum** — agents не делают security mistakes (capability-based)
4. **Zig** — no hidden alloc, agents не делают memory bugs
5. **Cap'n Proto** — agents читают `.capnp`, понимают контракт
6. **Zenoh** — agents координируются P2P, без broker
7. **Cage** — agents тестируют headless, без GUI
8. **Semantic Markup** — agents читают контракты, не угадывают
9. **hubd** — agents координируются через claims.jsonl

**Результат:** agents тратят 20% времени на стек, 80% на actual work.

---

## Migration Strategy

### Не мигрировать на mainstream

**Почему:**
- Mainstream стек оптимизирован для humans, не agents
- Migration cost > benefit (agents могут патчить текущий стек)
- Niche стек = competitive advantage (никто не копирует)

### Развивать текущий стек

**Приоритеты:**
1. ✅ Semantic markup — agents читают контракты
2. ✅ hubd — agents координируются
3. ✅ Tests — agents верифицируют
4. ✅ Documentation — agents понимают архитектуру

### Когда мигрировать?

**Никогда.** bsdOS — это research project, доказывающий, что agents могут развивать OS с niche стеком.

Если bsdOS станет product (v1.0+), рассмотреть:
- Rust wrappers для Zig HAL (если agents не справляются с Zig)
- gRPC bridge для Zenoh (если нужен interop с external services)
- Docker compatibility layer (если нужен deploy на K8s)

Но **не менять core стек**.

---

## Decision Log

| Date | Decision | Rationale |
|------|----------|-----------|
| 2026-06-06 | FreeBSD over Linux | rc.d проще для agents, jails декларативнее |
| 2026-06-06 | Zig over Rust | No hidden alloc, agents не делают memory bugs |
| 2026-06-06 | Zenoh over MQTT/gRPC | P2P, agents не координируют broker |
| 2026-06-06 | Cap'n Proto over Protobuf | Zero-copy, schema-first, agents читают `.capnp` |
| 2026-06-06 | Cage/Weston over Sway | Headless, agents тестируют без GUI |
| 2026-06-06 | Jails over Docker | Декларативные, agents пишут конфиг |
| 2026-06-06 | Semantic Markup over JSDoc | Agents читают контракты, не угадывают |
| 2026-06-12 | **Не мигрировать на mainstream** | Стек оптимизирован для agents, не humans |

---

## References

- [CLAUDE.md](CLAUDE.md) — hard rules, tech choices
- [AGENTS.md](AGENTS.md) — multi-agent protocol
- [github.com/bzdOS/sema](https://github.com/bzdOS/sema) — контрактная разметка
- [PLAN-bsdos-vision.md](PLAN-bsdos-vision.md) — видение проекта

---

**Last updated:** 2026-06-12
**Owner:** m3 (architecture review)
