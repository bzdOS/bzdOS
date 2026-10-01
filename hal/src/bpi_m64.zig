// START_AI_HEADER
// MODULE: hal/src/bpi_m64.zig
// PURPOSE: BPI-M64 hardware constants — Banana Pi BPI-M64 (Allwinner A64, FreeBSD 15.1 aarch64).
// INTENT: Single source of truth for all board-level device paths and hardware parameters
//         for the Chimp v0.2 target.  Imported by HAL subsystems that gate on
//         platform.current == .bpi_m64.  All values are comptime constants —
//         zero runtime overhead.
// DEPENDENCIES: none.
// PUBLIC_API: soc, cpu_cores, i2c_buses, gpio_base, eth_iface, usb_host, audio_dev.
// END_AI_HEADER

// bpi_m64:start
//   purpose: Export board-level hardware constants for Banana Pi BPI-M64 (Allwinner A64)
//            so HAL subsystems can reference canonical device paths without hardcoding
//            strings at call sites.
//   input:   none — pure comptime constants.
//   output:  pub const fields (see PUBLIC_API above).
//   sideEffects: none.

// soc:start
//   purpose: Human-readable SoC identifier for log messages and hal_version feature lists.
//   input:   none.  output: []const u8.  sideEffects: none.
pub const soc: []const u8 = "Allwinner A64";
// soc:end

// cpu_cores:start
//   purpose: Number of ARM Cortex-A53 cores on the A64 SoC (used for cpu_stats scaling).
//   input:   none.  output: u8.  sideEffects: none.
pub const cpu_cores: u8 = 4;
// cpu_cores:end

// i2c_buses:start
//   purpose: FreeBSD iic(4) device paths for all three A64 TWI (I2C) controllers.
//            TWI0 = /dev/iic0 (sensor bus), TWI1 = /dev/iic1, TWI2 = /dev/iic2.
//   input:   none.  output: [3][]const u8.  sideEffects: none.
pub const i2c_buses = [_][]const u8{ "/dev/iic0", "/dev/iic1", "/dev/iic2" };
// i2c_buses:end

// gpio_base:start
//   purpose: FreeBSD gpio(4) device path for the A64 GPIO controller.
//   input:   none.  output: []const u8.  sideEffects: none.
pub const gpio_base: []const u8 = "/dev/gpio0";
// gpio_base:end

// eth_iface:start
//   purpose: FreeBSD network interface name for the Allwinner EMAC Gigabit Ethernet.
//            On FreeBSD 15.1 aarch64 the driver registers as awg(4).
//   input:   none.  output: []const u8.  sideEffects: none.
pub const eth_iface: []const u8 = "awg0";
// eth_iface:end

// usb_host:start
//   purpose: FreeBSD usb(4) device path for the on-board USB host controller.
//   input:   none.  output: []const u8.  sideEffects: none.
pub const usb_host: []const u8 = "/dev/usb";
// usb_host:end

// audio_dev:start
//   purpose: FreeBSD OSS audio device for the Allwinner sun4i-codec integrated on A64.
//            HAL audio_bridge reads/writes PCM through this path.
//   input:   none.  output: []const u8.  sideEffects: none.
pub const audio_dev: []const u8 = "/dev/dsp0";
// audio_dev:end
