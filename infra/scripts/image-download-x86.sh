#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."

# Bootstrap-образ для локального FreeBSD-билдера (см. PLAN-freebsd-local-build.md).
# 15.1-RELEASE на зеркале ещё нет (на 2026-06-06) — берём RC2 (фактически финал, p9fs есть).
# Свопнуть на RELEASE: FBSD_REL=15.1-RELEASE make image-download-x86 (когда появится VM-IMAGES/15.1-RELEASE/).
REL="${FBSD_REL:-15.1-RC2}"
URL="https://download.freebsd.org/releases/VM-IMAGES/${REL}/amd64/Latest/FreeBSD-${REL}-amd64-BASIC-CLOUDINIT-ufs.qcow2.xz"
OUT="freebsd-x86.qcow2.xz"

[ -f "$OUT" ] && { echo "Already downloaded: $OUT"; exit 0; }
echo "Downloading FreeBSD ${REL} amd64 (cloud-init, ~400MB)..."
# --noproxy '*': хостовый прокси не умеет FreeBSD зеркала, идём напрямую.
curl --noproxy '*' -L --progress-bar -o "$OUT" "$URL"
echo "Downloaded: $OUT"
