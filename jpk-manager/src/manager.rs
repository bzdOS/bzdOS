// START_AI_HEADER
// MODULE: jpk-manager/src/manager.rs
// PURPOSE: JPK package install/uninstall manager for bsdOS FreeBSD jails.
// INTENT: Install .jpk packages as ZFS-based FreeBSD jails with jail.conf generation.
// DEPENDENCIES: std, crate::manifest.
// PUBLIC_API: install_package, uninstall_package, parse_jpk, unpack_payload, generate_jail_conf.
// END_AI_HEADER

use std::fs;
use std::io::{self, Read};
use std::path::{Path, PathBuf};
use std::process::Command;
use crate::manifest::Manifest;

const JAILS_DIR: &str = "/jails/apps";
const JAIL_CONF_DIR: &str = "/etc/jail.conf.d";
const MAGIC: u32 = 0x4A504B00;

/// Установить .jpk пакет
// install_package:start
//   purpose: Install a .jpk package — parse, validate, create jail root, unpack payload, generate jail.conf.
//   input:  jpk_path: path to .jpk file.
//   output: Result<(), Box<dyn Error>>.
//   sideEffects: creates directories, writes files, executes zstd and tar subprocesses, writes jail.conf.
pub fn install_package(jpk_path: &str) -> Result<(), Box<dyn std::error::Error>> {
    println!("[pkgd] installing: {jpk_path}");

    // Читаем и валидируем файл
    let (manifest, payload) = parse_jpk(jpk_path)?;
    Manifest::validate_id(&manifest.id).map_err(|e| format!("bad app id: {e}"))?;

    let jail_root = PathBuf::from(JAILS_DIR).join(&manifest.id);
    let conf_path = PathBuf::from(JAIL_CONF_DIR).join(format!("{}.conf", manifest.id));

    // Создать директорию джейла
    fs::create_dir_all(&jail_root)?;
    println!("[pkgd] jail root: {}", jail_root.display());

    // Распаковать ZFS-образ (zstd | zfs receive)
    unpack_payload(&payload, &jail_root)?;

    // Сгенерировать jail.conf
    let conf = generate_jail_conf(&manifest, &jail_root);
    fs::write(&conf_path, &conf)?;
    println!("[pkgd] wrote jail conf: {}", conf_path.display());

    println!("[pkgd] installed {} v{}", manifest.name, manifest.version);
    Ok(())
}
// install_package:end

/// Удалить пакет
// uninstall_package:start
//   purpose: Remove an installed jail package — stop jail, unmount devfs, destroy ZFS dataset, remove config.
//   input:  app_id: jail application identifier.
//   output: Result<(), Box<dyn Error>>.
//   sideEffects: executes jail -r, umount, zfs destroy, deletes files and directories.
pub fn uninstall_package(app_id: &str) -> Result<(), Box<dyn std::error::Error>> {
    Manifest::validate_id(app_id).map_err(|e| format!("bad app id: {e}"))?;
    println!("[pkgd] uninstalling: {app_id}");

    // Остановить джейл если запущен
    let _ = Command::new("jail")
        .args(["-r", app_id])
        .output(); // игнорируем ошибку — jail может не быть запущен

    // Размонтировать devfs
    let devfs_path = format!("{}/{}/dev", JAILS_DIR, app_id);
    let _ = Command::new("umount").arg(&devfs_path).output();

    // Удалить ZFS датасет
    let dataset = format!("bsdos/apps/{app_id}");
    println!("[pkgd] destroying zfs dataset: {dataset}");
    let out = Command::new("zfs")
        .args(["destroy", "-r", &dataset])
        .output()?;
    if !out.status.success() {
        let err = String::from_utf8_lossy(&out.stderr);
        println!("[pkgd] zfs destroy warning: {err}");
    }

    // Удалить jail.conf
    let conf_path = PathBuf::from(JAIL_CONF_DIR).join(format!("{app_id}.conf"));
    if conf_path.exists() {
        fs::remove_file(&conf_path)?;
    }

    // Удалить директорию
    let jail_root = PathBuf::from(JAILS_DIR).join(app_id);
    if jail_root.exists() {
        fs::remove_dir_all(&jail_root)?;
    }

    println!("[pkgd] uninstalled {app_id}");
    Ok(())
}
// uninstall_package:end

// parse_jpk:start
//   purpose: Parse .jpk file — read header, validate magic, extract manifest and payload.
//   input:  path: file path to .jpk.
//   output: Result<(Manifest, Vec<u8>), Box<dyn Error>> — parsed manifest and raw payload.
//   sideEffects: reads .jpk file.
fn parse_jpk(path: &str) -> Result<(Manifest, Vec<u8>), Box<dyn std::error::Error>> {
    let mut file = fs::File::open(path)?;
    let mut header = [0u8; 12];
    file.read_exact(&mut header)?;

    let magic = u32::from_le_bytes(header[0..4].try_into()?);
    if magic != MAGIC {
        return Err(format!("not a .jpk file (magic={magic:#010x})").into());
    }

    let _version = u32::from_le_bytes(header[4..8].try_into()?);
    let manifest_len = u32::from_le_bytes(header[8..12].try_into()?) as usize;

    let mut manifest_bytes = vec![0u8; manifest_len];
    file.read_exact(&mut manifest_bytes)?;
    let manifest: Manifest = serde_json::from_slice(&manifest_bytes)?;

    let mut payload = Vec::new();
    file.read_to_end(&mut payload)?;

    Ok((manifest, payload))
}
// parse_jpk:end

// unpack_payload:start
//   purpose: Decompress zstd payload and extract tar archive into jail root directory.
//   input:  payload: zstd-compressed tar bytes, jail_root: target extraction directory.
//   output: Result<(), Box<dyn Error>>.
//   sideEffects: executes zstd -d and tar -xf subprocesses with piped data.
fn unpack_payload(payload: &[u8], jail_root: &Path) -> Result<(), Box<dyn std::error::Error>> {
    use std::io::Write;
    use std::process::Stdio;

    println!("[pkgd] unpacking {} bytes of payload to {}", payload.len(), jail_root.display());

    // Формат payload: zstd-сжатый tar
    // Разжимаем через: zstd -d | tar -xf - -C <jail_root>
    // Через pipeline: zstd читает stdin, отдаёт в tar
    let mut zstd_proc = Command::new("zstd")
        .args(["-d", "--stdout"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()?;

    let mut tar_proc = Command::new("tar")
        .args(["-xf", "-", "-C", jail_root.to_str().ok_or("bad path")?])
        .stdin(zstd_proc.stdout.take().ok_or("no zstd stdout")?)
        .spawn()?;

    if let Some(mut stdin) = zstd_proc.stdin.take() {
        stdin.write_all(payload)?;
    }

    let zstd_status = zstd_proc.wait()?;
    let tar_status = tar_proc.wait()?;

    if !zstd_status.success() {
        return Err(format!("zstd failed: {}", zstd_status).into());
    }
    if !tar_status.success() {
        return Err(format!("tar failed: {}", tar_status).into());
    }
    Ok(())
}
// unpack_payload:end

// generate_jail_conf:start
//   purpose: Generate FreeBSD jail.conf content from Manifest metadata.
//   input:  manifest: package Manifest, jail_root: jail root path.
//   output: String — jail.conf content.
//   sideEffects: none.
fn generate_jail_conf(manifest: &Manifest, jail_root: &Path) -> String {
    let network_section = if manifest.network {
        "    ip4 = inherit;\n"
    } else {
        "    ip4 = disable;\n    ip6 = disable;\n"
    };

    format!(
        r#"# Сгенерировано bsdos-pkgd для {id} v{version}
{id} {{
    path = "{root}";
    host.hostname = "{id}";
    persist;
    mount.devfs;
    devfs_ruleset = {ruleset};
    exec.start = "{entry}";
    exec.stop = "/bin/sh /etc/rc.shutdown";
{network}}}
"#,
        id = manifest.id,
        version = manifest.version,
        root = jail_root.display(),
        ruleset = manifest.devfs_ruleset,
        entry = manifest.entry,
        network = network_section,
    )
}
// generate_jail_conf:end
