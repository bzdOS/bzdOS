@0xa1b2c3d4e5f60718;

# bsdOS Core API — единая Cap'n Proto схема.
# Все IPC внутри устройства через Unix-сокеты, zero-copy.
#
# Wire encoding (hand-rolled, no capnp compiler needed):
#   SysCommand:  16 bytes fixed (framing+ptr+data), zero variable fields
#   TouchEvent:  32 bytes fixed (framing+ptr+data)
#   AudioPacket: variable (framing+ptr+seq+ts+list_ptr+opus_bytes)

# ── Системные команды (SysCommand) ───────────────────────────────────────────
#
# Fixed wire layout (16 bytes total):
#   [0..4]  framing: 0 (1 segment)
#   [4..8]  seg_size: 1 word (struct only, no list data)
#   [8..16] struct ptr: dataWords=1, ptrWords=0
#   [8..9]  cmdId  (UInt8)  — PING|FREEZE|THAW|HIBERNATE|PRE_THAW|SYNC_PUSH
#   [9..10] _pad
#   [10..12] appId lower 16 bits
#   [12..14] appId upper 16 bits
#   [14..16] payload (UInt16)
#
# Command IDs:
#   PING=1, FREEZE=2, THAW=3, HIBERNATE=4, PRE_THAW=5, SYNC_PUSH=6

struct SysCommand {
  cmdId   @0 :UInt8;    # команда
  appId   @1 :UInt32;   # ID приложения/jail
  payload @2 :UInt16;   # параметр команды
}

# ── Touch события (TouchEvent) ────────────────────────────────────────────────
#
# Fixed wire layout (32 bytes):
#   [0..8]   framing + seg_size
#   [8..16]  struct ptr: dataWords=2, ptrWords=0
#   [16..18] x (UInt16)
#   [18..20] y (UInt16)
#   [20..22] state (UInt8) + pad
#   [22..24] _pad
#   [24..32] timestampMs (UInt64)

struct TouchEvent {
  x           @0 :UInt16;  # координата X (пиксели)
  y           @1 :UInt16;  # координата Y (пиксели)
  state       @2 :UInt8;   # 0=hover 1=move 2=press 3=lift
  timestampMs @3 :UInt64;  # монотонная метка (мс)
}

# ── Аудио фреймы (AudioPacket) ────────────────────────────────────────────────
#
# Variable wire layout:
#   [0..8]   framing + seg_size
#   [8..16]  struct ptr: dataWords=2, ptrWords=1
#   [16..24] sequenceNumber (UInt64)
#   [24..28] timestampMs (UInt32)
#   [28..32] _pad
#   [32..40] list ptr for opusPayload (Data)
#   [40..]   raw Opus bytes

struct AudioPacket {
  sequenceNumber @0 :UInt64;  # счётчик фреймов
  timestampMs    @1 :UInt32;  # мс с начала звонка
  opusPayload    @2 :Data;    # сырые Opus-байты (20мс фрейм ≈ 100-1400 байт)
}
