# Vendored copy — github.com/bzdOS/WLStream

This directory is a **vendored snapshot** of the WLStream crate.

- Canonical upstream: https://github.com/bzdOS/WLStream
- Local git repo: `~/wlstream` (separate, do not rm)
- Reason for vendoring: VM dev-vm mounts only `/srv/bsdos` via 9p → `/mnt/bsdos`.
  `cargo build` on VM cannot reach `~/wlstream`. Vendoring fixes the build path.

## To sync from upstream

```sh
rsync -a --delete --exclude='.git' ~/wlstream/ /srv/bsdos/wlstream/
rm -f /srv/bsdos/wlstream/VENDORED.md   # preserve this file
# then re-add VENDORED.md and commit
```

Do NOT edit this copy directly for feature work — edit `~/wlstream`, test there,
then sync here and commit both.
