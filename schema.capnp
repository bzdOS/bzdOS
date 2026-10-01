@0x8e2f268d3ac0b9e6;

# Телеметрия железа: uptime, батарея, CPU
# Flat struct — 2 data words (16 bytes), 0 pointer words.
# Бинарный layout (little-endian, всегда 32 байта с framing):
#   [0..4]   message framing (segment count - 1 = 0)
#   [4..8]   segment 0 size in 64-bit words = 3 (ptr + 2 data words)
#   [8..16]  root struct pointer: type=0, offset=0, dataWords=2, ptrWords=0
#   [16..24] uptime (uint64)
#   [24..28] batteryLevel (uint32)
#   [28..32] cpuUsage (uint32)

struct HardwareStatus {
  uptime       @0 :UInt64;   # секунды аптайма ядра
  batteryLevel @1 :UInt32;   # 0-100 %
  cpuUsage     @2 :UInt32;   # 0-100 %
}

# Состояние одного jail — публикуется в Zenoh bsdos/telemetry/jail/<name>
# Flat struct — 2 data words (16 bytes), 1 pointer word.
# Бинарный layout (little-endian):
#   [0..4]   message framing (segment count - 1 = 0)
#   [4..8]   segment 0 size in 64-bit words = 4 (ptr + 2 data + 1 ptr word)
#   [8..16]  root struct pointer: type=0, offset=0, dataWords=2, ptrWords=1
#   [16..24] jid (uint32) | frozen (bool) | reserved (28 bits)
#   [24..32] memUsed (uint64)
#   [32..40] name Text pointer (list, 48-bit offset + 16-bit length)

struct JailStatus {
  jid     @0 :UInt32;   # FreeBSD jail ID (получается из jail_get)
  frozen  @1 :Bool;     # SIGSTOP активен (process pause state)
  memUsed @2 :UInt64;   # RSS в байтах (из procfs)
  name    @3 :Text;     # имя jail (appA, appB, ...) — unique identifier
}

# Touch-событие от HAL — 240Hz, Zenoh bsdos/input/touch
# Compact struct — 2 data words (16 bytes), 0 pointer words.
# Бинарный layout (little-endian, 32 байта с framing):
#   [0..4]   message framing (segment count - 1 = 0)
#   [4..8]   segment 0 size in 64-bit words = 2 (root only)
#   [8..16]  root struct pointer: type=0, offset=0, dataWords=2, ptrWords=0
#   [16..18] x (uint16)
#   [18..20] y (uint16)
#   [20..21] pressure (uint8)
#   [21..22] finger (uint8)
#   [22..24] reserved (16 bits, aligned)
#   [24..32] tsUsec (uint64)

struct TouchEvent {
  x        @0 :UInt16;   # X координата в пикселях (0-display_width)
  y        @1 :UInt16;   # Y координата в пикселях (0-display_height)
  pressure @2 :UInt8;    # давление (0-255, 0=contact, 255=max pressure)
  finger   @3 :UInt8;    # finger ID для multi-touch (0-9 на PinePhone)
  tsUsec   @4 :UInt64;   # timestamp в микросекундах (от HAL clock)
}

# Wayland wire message — Zenoh bsdos/global/wayland/stream
# Variable-size struct из-за payload :Data, 2 data + 1 pointer word.
# Бинарный layout:
#   [0..4]   message framing
#   [4..8]   segment 0 size in 64-bit words (зависит от payload size)
#   [8..16]  root struct pointer: type=0, offset=0, dataWords=2, ptrWords=1
#   [16..20] msgId (uint32)
#   [20..24] objId (uint32)
#   [24..26] opCode (uint16)
#   [26..28] reserved (16 bits, aligned)
#   [28..36] payload Data pointer (48-bit byte offset + 32-bit word count)

struct WaylandPacket {
  msgId   @0 :UInt32;    # message sequence number для debugging
  objId   @1 :UInt32;    # Wayland object ID (wl_object@ID)
  opCode  @2 :UInt16;    # Wayland opcode (method index)
  payload @3 :Data;      # raw Wayland bytes (zero-copy, hand-rolled parsing)
}

# ── Coupling-store primitives (Ярус 2, SPEC_coupling_v1 §3) ───────────────────
# Serialised over Zenoh bsdos/cf/<group>/… and the couplingd unix-socket
# (control text CMD ARG\n, data Cap'n Proto length-prefixed binary).

# Session/lease handle — корень всех coupling-объектов.
# Смерть узла → TTL истёк → все его locks/ephemeral-keys/svc-reg автоматически сняты.
struct Session {
  id    @0 :UInt64;   # session identifier (random, node-unique)
  node  @1 :UInt64;   # node identifier (Zenoh UUID or sysctl hw.hostid)
  ttlMs @2 :UInt32;   # lease TTL in milliseconds (renewable via KEEPALIVE)
  epoch @3 :UInt64;   # monotonic epoch counter (incremented on leader change)
}

# Lock acquisition mode — shared (read-lock) or exclusive (write-lock).
enum Mode {
  shared    @0;   # multiple holders allowed (read)
  exclusive @1;   # single holder (write); fence++ on each acquire
}

# Distributed lock grant returned by LOCK ACQ.
# fence — monotonic per-key fencing token; storage/VFS rejects stale tokens → no split-brain.
struct LockGrant {
  key   @0 :Text;   # lock key (arbitrary path-like string)
  mode  @1 :Mode;   # granted mode
  fence @2 :UInt64; # fencing token (monotonically increasing per key on each exclusive acquire)
}

# CAS/PUT entry for the linearisable KV store.
# expectVer=0 means unconditional write; fence is forwarded to VFS for fenced writes.
struct KvPut {
  key       @0 :Text;   # store key
  val       @1 :Data;   # value payload (Cap'n Proto or raw bytes)
  expectVer @2 :UInt64; # expected current version for CAS (0 = unconditional)
  fence     @3 :UInt64; # fencing token from associated LockGrant (0 = no fence)
}

# Queue entry for ordered persistent queues (QPUSH/QPOP).
struct QEntry {
  queue   @0 :Text;   # queue name
  payload @1 :Data;   # message payload
  seq     @2 :UInt64; # sequence number assigned by couplingd on enqueue (0 before assign)
}

# Service registration record (SvcRegistry, SPEC §3 SVC REG/RESOLVE).
struct SvcReg {
  name @0 :Text;    # service name (e.g. "pg-matrix", "synapse")
  node @1 :UInt64;  # node hosting the service instance
  sid  @2 :UInt64;  # session ID owning this registration (auto-expires with session)
}
