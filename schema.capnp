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
