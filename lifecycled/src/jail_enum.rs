// START_AI_HEADER
// MODULE: lifecycled/src/jail_enum.rs
// PURPOSE: Real FreeBSD jail enumeration + per-jail PID discovery for the
//          lifecycle daemon. Resolves active jails via jail_get(2) and the
//          processes inside each jail via sysctl(KERN_PROC_PROC) filtered by
//          kinfo_proc.ki_jid.
// INTENT: Replace the previous kill(-jid) heuristic (JID is NOT a PGID on
//         FreeBSD) with PID-targeted signalling. freeze/thaw/kill now send
//         SIGSTOP/SIGCONT/SIGKILL to every real PID belonging to the jail.
// DEPENDENCIES: libc (jail_get/sysctl/kill, kinfo_proc, CTL_KERN/KERN_PROC*).
//               unsafe only for these FFI syscalls (project rule).
// PUBLIC_API: JailInfo, list_jails(), jail_pids(), jid_by_name(),
//             signal_jail_pids(), Sig.
// END_AI_HEADER

// FreeBSD jail enumeration.
//
// Two primitives, both via direct syscalls (no fork/exec, no jls/ps parsing on
// the hot path):
//
//   1. list_jails()  — iterate jail_get(2) with the "lastjid" key, walking the
//                      kernel jail table to collect {jid, name} for every active
//                      jail. This is the canonical way prison_get(2)/jail_get(2)
//                      enumeration works (see jail(8) / libjail jailparam_get).
//
//   2. jail_pids(jid) — sysctl(CTL_KERN, KERN_PROC, KERN_PROC_PROC) returns one
//                      kinfo_proc per process; we filter ki_jid == jid. kinfo_proc
//                      layout differs between amd64/aarch64 — we take it from the
//                      libc crate (libc::kinfo_proc) so the offsets are correct
//                      per target, never hand-rolled.
//
// freeze/thaw/kill then map a jail name → jid → [pids] → kill(pid, sig) per PID.
//
// Non-FreeBSD (Linux dev host): stubs return an empty jail list / "unsupported"
// errors so the crate still compiles for `cargo check` on the build host, but no
// real signalling happens off FreeBSD.

/// One active jail: its kernel JID and its name (== bsdOS app_id).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct JailInfo {
    pub jid: i32,
    pub name: String,
}

/// Signal selector — kept tiny and explicit so the public API does not leak
/// raw libc signal ints into callers.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Sig {
    Stop,
    Cont,
    Kill,
    /// Probe only (signal 0) — checks delivery permission without sending.
    Probe,
}

#[cfg(target_os = "freebsd")]
impl Sig {
    // raw:start
    //   purpose: Map the Sig enum to the corresponding libc signal number.
    //   input:  self — the signal selector
    //   output: c_int signal number (0 for Probe)
    //   sideEffects: none
    fn raw(self) -> libc::c_int {
        match self {
            Sig::Stop => libc::SIGSTOP,
            Sig::Cont => libc::SIGCONT,
            Sig::Kill => libc::SIGKILL,
            Sig::Probe => 0,
        }
    }
    // raw:end
}

// ── FreeBSD implementation ────────────────────────────────────────────────────

#[cfg(target_os = "freebsd")]
mod imp {
    use super::{JailInfo, Sig};
    use std::ffi::CString;
    use std::mem;

    /// errno read helper — FreeBSD exposes the per-thread errno via __error().
    // errno:start
    //   purpose: Read the current thread errno on FreeBSD via __error().
    //   input:  none
    //   output: i32 errno value
    //   sideEffects: reads thread-local errno
    fn errno() -> i32 {
        unsafe { *libc::__error() }
    }
    // errno:end

    /// Resolve a jail name to its numeric JID via jail_get(2).
    // jid_by_name:start
    //   purpose: Resolve a jail name to numeric JID via a direct jail_get(2) syscall.
    //   input:  name — jail name string
    //   output: Result<i32, String> (JID on success, error description on failure)
    //   sideEffects: calls jail_get(2)
    pub fn jid_by_name(name: &str) -> Result<i32, String> {
        let name_cstr = CString::new(name).map_err(|e| format!("jail name nul: {e}"))?;
        let key_jid = CString::new("jid").map_err(|e| e.to_string())?;
        let key_name = CString::new("name").map_err(|e| e.to_string())?;

        let mut jid: i32 = 0;

        let mut iov = [
            libc::iovec {
                iov_base: key_name.as_ptr() as *mut _,
                iov_len: key_name.as_bytes_with_nul().len(),
            },
            libc::iovec {
                iov_base: name_cstr.as_ptr() as *mut _,
                iov_len: name_cstr.as_bytes_with_nul().len(),
            },
            libc::iovec {
                iov_base: key_jid.as_ptr() as *mut _,
                iov_len: key_jid.as_bytes_with_nul().len(),
            },
            libc::iovec {
                iov_base: &mut jid as *mut i32 as *mut _,
                iov_len: mem::size_of::<i32>(),
            },
        ];

        let ret = unsafe { libc::jail_get(iov.as_mut_ptr(), iov.len() as u32, 0) };
        if ret < 0 {
            Err(format!("jail_get({name}): errno={}", errno()))
        } else {
            Ok(jid)
        }
    }
    // jid_by_name:end

    /// Enumerate all active jails by walking the kernel jail table with the
    /// "lastjid" key — the canonical jail_get(2) iteration idiom.
    // list_jails:start
    //   purpose: Enumerate every active jail via repeated jail_get(2) using the
    //            "lastjid" iteration key, collecting {jid, name} pairs.
    //   input:  none
    //   output: Result<Vec<JailInfo>, String> (active jails, or error)
    //   sideEffects: calls jail_get(2) once per jail (plus final ENOENT)
    pub fn list_jails() -> Result<Vec<JailInfo>, String> {
        let key_lastjid = CString::new("lastjid").map_err(|e| e.to_string())?;
        let key_jid = CString::new("jid").map_err(|e| e.to_string())?;
        let key_name = CString::new("name").map_err(|e| e.to_string())?;

        // MAXHOSTNAMELEN-ish buffer for the jail name (MAXHOSTNAMELEN = 256 on FreeBSD).
        const NAME_CAP: usize = 256;

        let mut jails: Vec<JailInfo> = Vec::new();
        let mut lastjid: i32 = 0;

        loop {
            let mut cur_jid: i32 = 0;
            let mut name_buf = [0u8; NAME_CAP];

            let mut iov = [
                // in:  lastjid = <previous jid>
                libc::iovec {
                    iov_base: key_lastjid.as_ptr() as *mut _,
                    iov_len: key_lastjid.as_bytes_with_nul().len(),
                },
                libc::iovec {
                    iov_base: &mut lastjid as *mut i32 as *mut _,
                    iov_len: mem::size_of::<i32>(),
                },
                // out: jid
                libc::iovec {
                    iov_base: key_jid.as_ptr() as *mut _,
                    iov_len: key_jid.as_bytes_with_nul().len(),
                },
                libc::iovec {
                    iov_base: &mut cur_jid as *mut i32 as *mut _,
                    iov_len: mem::size_of::<i32>(),
                },
                // out: name
                libc::iovec {
                    iov_base: key_name.as_ptr() as *mut _,
                    iov_len: key_name.as_bytes_with_nul().len(),
                },
                libc::iovec {
                    iov_base: name_buf.as_mut_ptr() as *mut _,
                    iov_len: NAME_CAP,
                },
            ];

            let ret = unsafe { libc::jail_get(iov.as_mut_ptr(), iov.len() as u32, 0) };
            if ret < 0 {
                // ENOENT == no more jails: clean end of iteration.
                if errno() == libc::ENOENT {
                    break;
                }
                return Err(format!("jail_get(lastjid={lastjid}): errno={}", errno()));
            }

            // jail_get returns the matched jid; advance the cursor.
            lastjid = ret;

            let name = cstr_buf_to_string(&name_buf);
            jails.push(JailInfo { jid: ret, name });

            // Safety valve: kernel JIDs are bounded, but never loop unbounded.
            if jails.len() > 100_000 {
                return Err("jail enumeration exceeded sane bound".to_string());
            }
        }

        Ok(jails)
    }
    // list_jails:end

    /// Decode a NUL-terminated C string out of a fixed byte buffer.
    // cstr_buf_to_string:start
    //   purpose: Convert a NUL-terminated byte buffer (kernel-filled) to a String.
    //   input:  buf — byte buffer that may contain a trailing NUL and garbage after
    //   output: String up to the first NUL (lossy UTF-8)
    //   sideEffects: none
    fn cstr_buf_to_string(buf: &[u8]) -> String {
        let end = buf.iter().position(|&b| b == 0).unwrap_or(buf.len());
        String::from_utf8_lossy(&buf[..end]).into_owned()
    }
    // cstr_buf_to_string:end

    /// All PIDs whose kinfo_proc.ki_jid == jid.
    // jail_pids:start
    //   purpose: List PIDs of all processes inside a jail by reading the full
    //            process table via sysctl(KERN_PROC_PROC) and filtering ki_jid.
    //   input:  jid — numeric jail id
    //   output: Result<Vec<i32>, String> (process pids in the jail, or error)
    //   sideEffects: calls sysctl(2) twice (size probe + fetch)
    pub fn jail_pids(jid: i32) -> Result<Vec<i32>, String> {
        // mib: CTL_KERN.KERN_PROC.KERN_PROC_PROC — every process, one record each.
        let mib: [libc::c_int; 3] = [libc::CTL_KERN, libc::KERN_PROC, libc::KERN_PROC_PROC];

        // First call: probe the required buffer length (oldp = null).
        let mut len: libc::size_t = 0;
        let rc = unsafe {
            libc::sysctl(
                mib.as_ptr(),
                mib.len() as libc::c_uint,
                std::ptr::null_mut(),
                &mut len,
                std::ptr::null(),
                0,
            )
        };
        if rc != 0 {
            return Err(format!("sysctl(KERN_PROC_PROC) size probe: errno={}", errno()));
        }
        if len == 0 {
            return Ok(Vec::new());
        }

        let proc_sz = mem::size_of::<libc::kinfo_proc>();
        // Over-allocate a little: the table can grow between the two calls.
        let slack = len + proc_sz * 16;
        let count = slack / proc_sz + 1;
        let mut buf: Vec<libc::kinfo_proc> = Vec::with_capacity(count);
        let mut got: libc::size_t = (count * proc_sz) as libc::size_t;

        let rc = unsafe {
            libc::sysctl(
                mib.as_ptr(),
                mib.len() as libc::c_uint,
                buf.as_mut_ptr() as *mut libc::c_void,
                &mut got,
                std::ptr::null(),
                0,
            )
        };
        if rc != 0 {
            return Err(format!("sysctl(KERN_PROC_PROC) fetch: errno={}", errno()));
        }

        // got is bytes written; derive the real record count.
        let n = (got as usize) / proc_sz;
        // SAFETY: the kernel filled `n` valid kinfo_proc records into our buffer.
        unsafe { buf.set_len(n) };

        let mut pids: Vec<i32> = Vec::new();
        for kp in buf.iter() {
            if kp.ki_jid == jid {
                pids.push(kp.ki_pid as i32);
            }
        }
        Ok(pids)
    }
    // jail_pids:end

    /// Send a signal to every PID of a jail; returns the count signalled.
    // signal_jail_pids:start
    //   purpose: Resolve jail name → jid → pids and kill(pid, sig) each PID.
    //   input:  name — jail name; sig — Sig selector
    //   output: Result<usize, String> (number of PIDs the signal was delivered to)
    //   sideEffects: calls jail_get(2), sysctl(2), kill(2) per PID
    pub fn signal_jail_pids(name: &str, sig: Sig) -> Result<usize, String> {
        let jid = jid_by_name(name)?;
        let pids = jail_pids(jid)?;
        let raw = sig.raw();

        let mut delivered = 0usize;
        for pid in pids {
            let r = unsafe { libc::kill(pid, raw) };
            if r == 0 {
                delivered += 1;
            } else {
                // ESRCH (process gone) is benign during teardown; log others.
                let e = errno();
                if e != libc::ESRCH {
                    eprintln!("[jail_enum] kill({pid}, {raw}) on jail={name}: errno={e}");
                }
            }
        }
        Ok(delivered)
    }
    // signal_jail_pids:end
}

// ── Non-FreeBSD stubs (dev host compilation only) ─────────────────────────────

#[cfg(not(target_os = "freebsd"))]
mod imp {
    use super::{JailInfo, Sig};

    const UNSUPPORTED: &str = "jail enumeration unsupported off FreeBSD";

    // jid_by_name:start
    //   purpose: Stub — jail lookup is unavailable off FreeBSD.
    //   input:  _name — ignored
    //   output: Err(unsupported)
    //   sideEffects: none
    pub fn jid_by_name(_name: &str) -> Result<i32, String> {
        Err(UNSUPPORTED.to_string())
    }
    // jid_by_name:end

    // list_jails:start
    //   purpose: Stub — returns an empty jail list off FreeBSD so the crate builds.
    //   input:  none
    //   output: Ok(empty Vec)
    //   sideEffects: none
    pub fn list_jails() -> Result<Vec<JailInfo>, String> {
        Ok(Vec::new())
    }
    // list_jails:end

    // jail_pids:start
    //   purpose: Stub — no process table access off FreeBSD.
    //   input:  _jid — ignored
    //   output: Ok(empty Vec)
    //   sideEffects: none
    pub fn jail_pids(_jid: i32) -> Result<Vec<i32>, String> {
        Ok(Vec::new())
    }
    // jail_pids:end

    // signal_jail_pids:start
    //   purpose: Stub — no real signalling off FreeBSD.
    //   input:  _name, _sig — ignored
    //   output: Err(unsupported)
    //   sideEffects: none
    pub fn signal_jail_pids(_name: &str, _sig: Sig) -> Result<usize, String> {
        Err(UNSUPPORTED.to_string())
    }
    // signal_jail_pids:end
}

// ── Public re-exports (platform-neutral surface) ─────────────────────────────

pub use imp::{jail_pids, jid_by_name, list_jails, signal_jail_pids};

#[cfg(test)]
mod tests {
    use super::*;

    // The syscall-backed paths can only be exercised on FreeBSD with live jails,
    // so here we cover the platform-neutral data types and the stub contract that
    // keeps the daemon compiling + degrading safely on the Linux build host.

    #[test]
    fn jailinfo_roundtrip() {
        let j = JailInfo { jid: 7, name: "appBrowser".to_string() };
        assert_eq!(j.jid, 7);
        assert_eq!(j.name, "appBrowser");
        assert_eq!(j.clone(), j);
    }

    #[test]
    fn sig_variants_distinct() {
        assert_ne!(Sig::Stop, Sig::Cont);
        assert_ne!(Sig::Kill, Sig::Probe);
        // Copy semantics: cheap to pass by value.
        let s = Sig::Stop;
        let t = s;
        assert_eq!(s, t);
    }

    #[cfg(not(target_os = "freebsd"))]
    #[test]
    fn stubs_degrade_safely_off_freebsd() {
        // On the Linux dev host the daemon must compile and never pretend to
        // signal anything: enumeration is empty, lookups/signals are errors.
        assert_eq!(list_jails().expect("stub list ok"), Vec::<JailInfo>::new());
        assert_eq!(jail_pids(1).expect("stub pids ok"), Vec::<i32>::new());
        assert!(jid_by_name("appBrowser").is_err());
        assert!(signal_jail_pids("appBrowser", Sig::Stop).is_err());
    }
}
