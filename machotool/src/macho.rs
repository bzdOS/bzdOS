// START_AI_HEADER
// MODULE: ipa-runtime/machotool/src/macho.rs
// PURPOSE: Dependency-free Mach-O parser — extract LC_LOAD_DYLIB/WEAK/REEXPORT
//          deps, LC_RPATH entries, and architecture(s) of thin/fat images.
// INTENT: Tell vchroot/populate.sh which install-names dyld will resolve out of
//         DYLD_ROOT_PATH. Pure, bounds-checked, no unsafe, no external crates.
// DEPENDENCIES: std.
// PUBLIC_API: parse, MachInfo, Slice, Dep, DepKind, MachError.
// END_AI_HEADER

// macho.rs
//
// purpose:     Minimal, dependency-free Mach-O parser for the IPA runtime.
//              Extracts the load-time dylib dependencies (LC_LOAD_DYLIB and
//              friends), the LC_RPATH entries, and the CPU architecture(s) of a
//              thin or fat (universal) Mach-O image. This is what the vchroot
//              populate helper needs to know which install-names dyld will try
//              to resolve out of DYLD_ROOT_PATH.
// input:       A byte slice holding a complete Mach-O file (thin or fat).
// output:      `MachInfo` (one or more `Slice`s, each with arch + dep/rpath
//              lists), or a `MachError` describing why parsing failed.
// sideEffects: none — pure, allocation-only-for-results parsing over `&[u8]`.
//
// Safety: NO `unsafe`. All multi-byte reads go through checked slice helpers +
//         `u32::from_le_bytes` / `from_be_bytes`. A malformed/truncated file
//         yields `MachError`, never a panic.

use std::fmt;

// ---------------------------------------------------------------------------
// Mach-O magic numbers (see <mach-o/loader.h> and <mach-o/fat.h>).
// ---------------------------------------------------------------------------
const MH_MAGIC: u32 = 0xfeed_face; // 32-bit, host-endian (LE on our targets)
const MH_CIGAM: u32 = 0xcefa_edfe; // 32-bit, byte-swapped
const MH_MAGIC_64: u32 = 0xfeed_facf; // 64-bit, host-endian
const MH_CIGAM_64: u32 = 0xcffa_edfe; // 64-bit, byte-swapped

const FAT_MAGIC: u32 = 0xcafe_babe; // fat header, big-endian on disk
const FAT_CIGAM: u32 = 0xbeba_feca; // fat header, byte-swapped

// ---------------------------------------------------------------------------
// Load command constants (subset we care about).
// LC_REQ_DYLD (0x80000000) is OR'd onto some cmd ids; we mask it off before
// matching so e.g. LC_LOAD_WEAK_DYLIB (0x80000018) is recognised.
// ---------------------------------------------------------------------------
const LC_REQ_DYLD: u32 = 0x8000_0000;
const LC_LOAD_DYLIB: u32 = 0x0000_000c;
const LC_LOAD_WEAK_DYLIB: u32 = 0x0000_0018; // | LC_REQ_DYLD on disk
const LC_REEXPORT_DYLIB: u32 = 0x0000_001f; // | LC_REQ_DYLD on disk
const LC_RPATH: u32 = 0x0000_001c; // | LC_REQ_DYLD on disk

// ---------------------------------------------------------------------------
// CPU types (see <mach/machine.h>). CPU_ARCH_ABI64 = 0x01000000 sets the 64-bit
// bit; arm64 = 12 | ABI64, x86_64 = 7 | ABI64.
// ---------------------------------------------------------------------------
const CPU_TYPE_X86_64: u32 = 0x0100_0007;
const CPU_TYPE_ARM64: u32 = 0x0100_000c;
const CPU_TYPE_X86: u32 = 0x0000_0007;
const CPU_TYPE_ARM: u32 = 0x0000_000c;

/// What kind of dependency a path came from.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DepKind {
    /// `LC_LOAD_DYLIB` — a hard, must-resolve dependency.
    Load,
    /// `LC_LOAD_WEAK_DYLIB` — may be absent at load time.
    Weak,
    /// `LC_REEXPORT_DYLIB` — re-exported umbrella dependency.
    Reexport,
}

impl DepKind {
    /// purpose: short tag for human/diagnostic output.
    /// input:   self. output: static label. sideEffects: none.
    pub fn tag(self) -> &'static str {
        match self {
            DepKind::Load => "LOAD",
            DepKind::Weak => "WEAK",
            DepKind::Reexport => "REEXPORT",
        }
    }
}

/// One dependent-library reference (an install-name path + how it was declared).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Dep {
    pub kind: DepKind,
    pub path: String,
}

/// Parsed view of a single thin Mach-O image (one architecture).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Slice {
    /// Human-readable arch name (e.g. "arm64", "x86_64", or "cputype:0x...").
    pub arch: String,
    /// Raw cputype field, for callers that want the exact value.
    pub cputype: u32,
    /// LC_LOAD_DYLIB / LC_LOAD_WEAK_DYLIB / LC_REEXPORT_DYLIB targets.
    pub deps: Vec<Dep>,
    /// LC_RPATH entries.
    pub rpaths: Vec<String>,
}

/// Parsed view of a whole file: one `Slice` (thin) or many (fat/universal).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MachInfo {
    pub slices: Vec<Slice>,
}

/// Parse failures. No panics escape the parser — every fault is a variant here.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MachError {
    /// File shorter than the minimum header we needed to read.
    Truncated { need: usize, have: usize },
    /// First 4 bytes were not any recognised Mach-O / fat magic.
    BadMagic(u32),
    /// A field (offset/size/count) pointed outside the file.
    OutOfBounds { what: &'static str },
    /// A load command claimed a size that cannot be valid.
    BadLoadCommand { what: &'static str },
}

impl fmt::Display for MachError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            MachError::Truncated { need, have } => {
                write!(f, "truncated Mach-O: needed {need} bytes, have {have}")
            }
            MachError::BadMagic(m) => write!(f, "not a Mach-O file (magic 0x{m:08x})"),
            MachError::OutOfBounds { what } => write!(f, "field out of bounds: {what}"),
            MachError::BadLoadCommand { what } => write!(f, "bad load command: {what}"),
        }
    }
}

impl std::error::Error for MachError {}

// ---------------------------------------------------------------------------
// Checked little-helpers over &[u8]. Each returns Err on truncation rather than
// indexing (which would panic).
// ---------------------------------------------------------------------------

// read_u32:start
/// purpose: read a u32 at `off` with the given endianness, bounds-checked.
/// input:   buffer, byte offset, big-endian flag.
/// output:  the value, or MachError::OutOfBounds.
/// sideEffects: none.
fn read_u32(buf: &[u8], off: usize, be: bool, what: &'static str) -> Result<u32, MachError> {
    let end = off.checked_add(4).ok_or(MachError::OutOfBounds { what })?;
    let bytes = buf.get(off..end).ok_or(MachError::OutOfBounds { what })?;
    let arr = [bytes[0], bytes[1], bytes[2], bytes[3]];
    Ok(if be {
        u32::from_be_bytes(arr)
    } else {
        u32::from_le_bytes(arr)
    })
}
// read_u32:end

// arch_name:start
/// purpose: classify a cputype field into a readable arch name.
/// input:   raw cputype. output: owned name. sideEffects: none.
fn arch_name(cputype: u32) -> String {
    match cputype {
        CPU_TYPE_X86_64 => "x86_64".to_string(),
        CPU_TYPE_ARM64 => "arm64".to_string(),
        CPU_TYPE_X86 => "i386".to_string(),
        CPU_TYPE_ARM => "arm".to_string(),
        other => format!("cputype:0x{other:08x}"),
    }
}
// arch_name:end

// parse:start
/// purpose: top-level entry — parse a thin or fat Mach-O byte buffer.
/// input:   full file bytes.
/// output:  MachInfo (>=1 slice) or MachError.
/// sideEffects: none.
pub fn parse(buf: &[u8]) -> Result<MachInfo, MachError> {
    // Magic is always the first 4 bytes. Fat magic is big-endian on disk.
    let magic = read_u32(buf, 0, false, "magic")?;
    match magic {
        FAT_MAGIC | FAT_CIGAM => parse_fat(buf, magic == FAT_MAGIC),
        MH_MAGIC | MH_MAGIC_64 | MH_CIGAM | MH_CIGAM_64 => {
            let slice = parse_thin(buf, 0)?;
            Ok(MachInfo {
                slices: vec![slice],
            })
        }
        other => Err(MachError::BadMagic(other)),
    }
}
// parse:end

// parse_fat:start
/// purpose: parse a fat/universal header and each of its arch slices.
/// input:   full file bytes, `swapped` = header is byte-swapped (FAT_CIGAM).
/// output:  MachInfo with one Slice per fat_arch entry.
/// sideEffects: none.
///
/// fat_header { u32 magic; u32 nfat_arch; } then nfat_arch * fat_arch:
/// fat_arch  { u32 cputype; u32 cpusubtype; u32 offset; u32 size; u32 align; }
/// All fields are big-endian on disk (swap if FAT_CIGAM).
fn parse_fat(buf: &[u8], swapped: bool) -> Result<MachInfo, MachError> {
    let be = !swapped; // FAT_MAGIC => big-endian on disk; FAT_CIGAM => little
    let nfat = read_u32(buf, 4, be, "nfat_arch")? as usize;

    // Guard against absurd counts (each fat_arch is 20 bytes).
    let table_bytes = nfat
        .checked_mul(20)
        .ok_or(MachError::OutOfBounds { what: "fat_arch table" })?;
    let table_end = 8usize
        .checked_add(table_bytes)
        .ok_or(MachError::OutOfBounds { what: "fat_arch table" })?;
    if table_end > buf.len() {
        return Err(MachError::OutOfBounds { what: "fat_arch table" });
    }

    let mut slices = Vec::with_capacity(nfat);
    for i in 0..nfat {
        let base = 8 + i * 20;
        let _cputype = read_u32(buf, base, be, "fat cputype")?;
        // cpusubtype at base+4 (unused), offset at base+8, size at base+12.
        let offset = read_u32(buf, base + 8, be, "fat offset")? as usize;
        let size = read_u32(buf, base + 12, be, "fat size")? as usize;

        let slice_end = offset
            .checked_add(size)
            .ok_or(MachError::OutOfBounds { what: "fat slice range" })?;
        if slice_end > buf.len() {
            return Err(MachError::OutOfBounds { what: "fat slice range" });
        }
        // Parse the embedded thin Mach-O starting at `offset`. We hand the whole
        // buffer + the slice start so the thin parser computes absolute offsets.
        slices.push(parse_thin(buf, offset)?);
    }
    Ok(MachInfo { slices })
}
// parse_fat:end

// parse_thin:start
/// purpose: parse one thin Mach-O image whose header begins at `base`.
/// input:   full file bytes, absolute offset of the mach_header.
/// output:  a populated Slice.
/// sideEffects: none.
///
/// mach_header(_64) {
///   u32 magic; u32 cputype; u32 cpusubtype; u32 filetype;
///   u32 ncmds;  u32 sizeofcmds; u32 flags; [u32 reserved (64-bit only)]
/// }
/// Load commands follow immediately after the header.
fn parse_thin(buf: &[u8], base: usize) -> Result<Slice, MachError> {
    let magic = read_u32(buf, base, false, "thin magic")?;
    let (be, header_len) = match magic {
        MH_MAGIC => (false, 28usize),
        MH_MAGIC_64 => (false, 32usize),
        MH_CIGAM => (true, 28usize),
        MH_CIGAM_64 => (true, 32usize),
        other => return Err(MachError::BadMagic(other)),
    };

    let cputype = read_u32(buf, base + 4, be, "cputype")?;
    let ncmds = read_u32(buf, base + 16, be, "ncmds")? as usize;
    let sizeofcmds = read_u32(buf, base + 20, be, "sizeofcmds")? as usize;

    // The load-command region is [cmd_start, cmd_start + sizeofcmds).
    let cmd_start = base
        .checked_add(header_len)
        .ok_or(MachError::OutOfBounds { what: "cmd region start" })?;
    let cmd_end = cmd_start
        .checked_add(sizeofcmds)
        .ok_or(MachError::OutOfBounds { what: "cmd region end" })?;
    if cmd_end > buf.len() {
        return Err(MachError::OutOfBounds { what: "cmd region" });
    }

    let mut deps = Vec::new();
    let mut rpaths = Vec::new();

    let mut off = cmd_start;
    for _ in 0..ncmds {
        // Each load_command starts: u32 cmd; u32 cmdsize;
        let hdr_end = off
            .checked_add(8)
            .ok_or(MachError::BadLoadCommand { what: "command header overflow" })?;
        if hdr_end > cmd_end {
            return Err(MachError::BadLoadCommand { what: "command header past region" });
        }
        let cmd = read_u32(buf, off, be, "lc cmd")?;
        let cmdsize = read_u32(buf, off + 4, be, "lc cmdsize")? as usize;

        // cmdsize must be at least the 8-byte header and must not run past the
        // declared command region; both guard against infinite / runaway loops.
        if cmdsize < 8 {
            return Err(MachError::BadLoadCommand { what: "cmdsize < 8" });
        }
        let next = off
            .checked_add(cmdsize)
            .ok_or(MachError::BadLoadCommand { what: "cmdsize overflow" })?;
        if next > cmd_end {
            return Err(MachError::BadLoadCommand { what: "cmdsize past region" });
        }

        match cmd & !LC_REQ_DYLD {
            // dylib_command: ...; u32 name_offset (lc_str union, offset from cmd).
            // Layout: cmd(4) cmdsize(4) name_off(4) timestamp(4) cur_ver(4) compat_ver(4)
            LC_LOAD_DYLIB | LC_LOAD_WEAK_DYLIB | LC_REEXPORT_DYLIB => {
                let kind = match cmd & !LC_REQ_DYLD {
                    LC_LOAD_DYLIB => DepKind::Load,
                    LC_LOAD_WEAK_DYLIB => DepKind::Weak,
                    _ => DepKind::Reexport,
                };
                let name_off = read_u32(buf, off + 8, be, "dylib name_off")? as usize;
                let path = read_lc_str(buf, off, cmdsize, name_off)?;
                deps.push(Dep { kind, path });
            }
            // rpath_command: cmd(4) cmdsize(4) path_off(4)
            LC_RPATH => {
                let path_off = read_u32(buf, off + 8, be, "rpath path_off")? as usize;
                let path = read_lc_str(buf, off, cmdsize, path_off)?;
                rpaths.push(path);
            }
            _ => { /* not interesting for dependency resolution */ }
        }

        off = next;
    }

    Ok(Slice {
        arch: arch_name(cputype),
        cputype,
        deps,
        rpaths,
    })
}
// parse_thin:end

// read_lc_str:start
/// purpose: read an lc_str — a NUL-terminated string embedded in a load command,
///          located at `str_off` bytes from the start of the command.
/// input:   buffer, absolute command offset, command size, in-command str offset.
/// output:  the decoded string (lossy UTF-8) or MachError if it runs out of range.
/// sideEffects: none.
fn read_lc_str(
    buf: &[u8],
    cmd_off: usize,
    cmdsize: usize,
    str_off: usize,
) -> Result<String, MachError> {
    // The string must start within the command and end at cmd_off + cmdsize.
    if str_off < 8 || str_off >= cmdsize {
        return Err(MachError::BadLoadCommand { what: "lc_str offset out of command" });
    }
    let abs_start = cmd_off
        .checked_add(str_off)
        .ok_or(MachError::BadLoadCommand { what: "lc_str start overflow" })?;
    let abs_end = cmd_off
        .checked_add(cmdsize)
        .ok_or(MachError::BadLoadCommand { what: "lc_str end overflow" })?;
    let region = buf
        .get(abs_start..abs_end)
        .ok_or(MachError::OutOfBounds { what: "lc_str region" })?;
    // String runs to the first NUL (or the whole region if unterminated).
    let bytes = match region.iter().position(|&b| b == 0) {
        Some(n) => &region[..n],
        None => region,
    };
    Ok(String::from_utf8_lossy(bytes).into_owned())
}
// read_lc_str:end

// ===========================================================================
// Tests — build synthetic Mach-O headers byte-by-byte and assert the parser
// extracts the right arch / deps / rpaths. No fixtures on disk required.
// ===========================================================================
#[cfg(test)]
mod tests {
    use super::*;

    // --- byte-assembly helpers -------------------------------------------
    fn push_u32_le(v: &mut Vec<u8>, x: u32) {
        v.extend_from_slice(&x.to_le_bytes());
    }
    fn push_u32_be(v: &mut Vec<u8>, x: u32) {
        v.extend_from_slice(&x.to_be_bytes());
    }

    /// Build a dylib_command (LC_LOAD_DYLIB family). Layout:
    /// cmd, cmdsize, name_off, timestamp, cur_ver, compat_ver, then name+NUL,
    /// padded to a 4-byte (or 8 for cleanliness) boundary.
    fn dylib_cmd(cmd: u32, name: &str) -> Vec<u8> {
        let name_off = 24u32; // 6 u32 fields precede the string
        let mut body = Vec::new();
        body.extend_from_slice(name.as_bytes());
        body.push(0); // NUL
        while body.len() % 4 != 0 {
            body.push(0);
        }
        let cmdsize = 24 + body.len();
        let mut out = Vec::new();
        push_u32_le(&mut out, cmd);
        push_u32_le(&mut out, cmdsize as u32);
        push_u32_le(&mut out, name_off);
        push_u32_le(&mut out, 0); // timestamp
        push_u32_le(&mut out, 0); // current_version
        push_u32_le(&mut out, 0); // compatibility_version
        out.extend_from_slice(&body);
        out
    }

    /// Build an rpath_command. Layout: cmd, cmdsize, path_off, then path+NUL.
    fn rpath_cmd(path: &str) -> Vec<u8> {
        let path_off = 12u32; // 3 u32 fields precede the string
        let mut body = Vec::new();
        body.extend_from_slice(path.as_bytes());
        body.push(0);
        while body.len() % 4 != 0 {
            body.push(0);
        }
        let cmdsize = 12 + body.len();
        let mut out = Vec::new();
        push_u32_le(&mut out, LC_RPATH | LC_REQ_DYLD);
        push_u32_le(&mut out, cmdsize as u32);
        push_u32_le(&mut out, path_off);
        out.extend_from_slice(&body);
        out
    }

    /// Build a complete 64-bit thin Mach-O from a set of load commands.
    fn thin64(cputype: u32, cmds: &[Vec<u8>]) -> Vec<u8> {
        let sizeofcmds: usize = cmds.iter().map(|c| c.len()).sum();
        let mut out = Vec::new();
        push_u32_le(&mut out, MH_MAGIC_64);
        push_u32_le(&mut out, cputype);
        push_u32_le(&mut out, 0); // cpusubtype
        push_u32_le(&mut out, 2); // filetype = MH_EXECUTE
        push_u32_le(&mut out, cmds.len() as u32); // ncmds
        push_u32_le(&mut out, sizeofcmds as u32);
        push_u32_le(&mut out, 0); // flags
        push_u32_le(&mut out, 0); // reserved (64-bit only)
        for c in cmds {
            out.extend_from_slice(c);
        }
        out
    }

    #[test]
    fn parses_arm64_load_dylib() {
        let cmds = vec![
            dylib_cmd(LC_LOAD_DYLIB, "/usr/lib/libSystem.B.dylib"),
            dylib_cmd(LC_LOAD_WEAK_DYLIB | LC_REQ_DYLD, "/usr/lib/libobjc.A.dylib"),
            dylib_cmd(LC_REEXPORT_DYLIB | LC_REQ_DYLD, "/usr/lib/libfoo.dylib"),
            rpath_cmd("@executable_path/../Frameworks"),
        ];
        let bin = thin64(CPU_TYPE_ARM64, &cmds);
        let info = parse(&bin).expect("parse ok");
        assert_eq!(info.slices.len(), 1);
        let s = &info.slices[0];
        assert_eq!(s.arch, "arm64");
        assert_eq!(s.cputype, CPU_TYPE_ARM64);
        assert_eq!(s.deps.len(), 3);
        assert_eq!(s.deps[0].kind, DepKind::Load);
        assert_eq!(s.deps[0].path, "/usr/lib/libSystem.B.dylib");
        assert_eq!(s.deps[1].kind, DepKind::Weak);
        assert_eq!(s.deps[1].path, "/usr/lib/libobjc.A.dylib");
        assert_eq!(s.deps[2].kind, DepKind::Reexport);
        assert_eq!(s.deps[2].path, "/usr/lib/libfoo.dylib");
        assert_eq!(s.rpaths, vec!["@executable_path/../Frameworks".to_string()]);
    }

    #[test]
    fn parses_x86_64_arch() {
        let cmds = vec![dylib_cmd(LC_LOAD_DYLIB, "/usr/lib/libSystem.B.dylib")];
        let bin = thin64(CPU_TYPE_X86_64, &cmds);
        let info = parse(&bin).expect("parse ok");
        assert_eq!(info.slices[0].arch, "x86_64");
    }

    #[test]
    fn parses_fat_two_slices() {
        // Build two thin images, then a fat header that points at them.
        let thin_x86 = thin64(
            CPU_TYPE_X86_64,
            &[dylib_cmd(LC_LOAD_DYLIB, "/usr/lib/libSystem.B.dylib")],
        );
        let thin_arm = thin64(
            CPU_TYPE_ARM64,
            &[dylib_cmd(LC_LOAD_DYLIB, "/usr/lib/libobjc.A.dylib")],
        );

        // Fat header: magic + nfat(2) + 2 * fat_arch(20 bytes) = 8 + 40 = 48.
        let header_len = 8 + 2 * 20;
        let off0 = header_len;
        let off1 = off0 + thin_x86.len();

        let mut fat = Vec::new();
        push_u32_be(&mut fat, FAT_MAGIC);
        push_u32_be(&mut fat, 2); // nfat_arch
        // arch 0: x86_64
        push_u32_be(&mut fat, CPU_TYPE_X86_64);
        push_u32_be(&mut fat, 0); // cpusubtype
        push_u32_be(&mut fat, off0 as u32);
        push_u32_be(&mut fat, thin_x86.len() as u32);
        push_u32_be(&mut fat, 0); // align
        // arch 1: arm64
        push_u32_be(&mut fat, CPU_TYPE_ARM64);
        push_u32_be(&mut fat, 0);
        push_u32_be(&mut fat, off1 as u32);
        push_u32_be(&mut fat, thin_arm.len() as u32);
        push_u32_be(&mut fat, 0);
        // payloads
        fat.extend_from_slice(&thin_x86);
        fat.extend_from_slice(&thin_arm);

        let info = parse(&fat).expect("fat parse ok");
        assert_eq!(info.slices.len(), 2);
        assert_eq!(info.slices[0].arch, "x86_64");
        assert_eq!(info.slices[0].deps[0].path, "/usr/lib/libSystem.B.dylib");
        assert_eq!(info.slices[1].arch, "arm64");
        assert_eq!(info.slices[1].deps[0].path, "/usr/lib/libobjc.A.dylib");
    }

    #[test]
    fn rejects_bad_magic() {
        let bin = vec![0xDE, 0xAD, 0xBE, 0xEF, 0, 0, 0, 0];
        match parse(&bin) {
            Err(MachError::BadMagic(0xEFBEADDE)) => {}
            other => panic!("expected BadMagic, got {other:?}"),
        }
    }

    #[test]
    fn rejects_truncated() {
        let bin = vec![0xCF]; // less than 4 bytes
        assert!(matches!(parse(&bin), Err(MachError::OutOfBounds { .. })));
    }

    #[test]
    fn rejects_runaway_cmdsize() {
        // ncmds=1 but cmdsize huge -> must be caught as past-region, not loop.
        let mut out = Vec::new();
        push_u32_le(&mut out, MH_MAGIC_64);
        push_u32_le(&mut out, CPU_TYPE_ARM64);
        push_u32_le(&mut out, 0);
        push_u32_le(&mut out, 2);
        push_u32_le(&mut out, 1); // ncmds = 1
        push_u32_le(&mut out, 8); // sizeofcmds = 8 (one tiny command)
        push_u32_le(&mut out, 0);
        push_u32_le(&mut out, 0);
        push_u32_le(&mut out, LC_LOAD_DYLIB);
        push_u32_le(&mut out, 0xFFFF_FFFF); // cmdsize lies
        assert!(matches!(
            parse(&out),
            Err(MachError::BadLoadCommand { .. })
        ));
    }
}
