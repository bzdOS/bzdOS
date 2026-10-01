#!/bin/sh

. "$(dirname "$0")/_ssh.sh"

REL="${FREEBSD_REL:-releng/15.1}"
DEPTH="${SRC_DEPTH:---depth 1}"

echo "[src-fetch] FreeBSD release: $REL, depth: $DEPTH"

if ssh_guest "test -d /usr/src/.git"; then
    echo "[src-fetch] /usr/src exists — updating..."
    ssh_root "git -C /usr/src fetch && git -C /usr/src status"
    echo "[src-fetch] Update complete"
    exit 0
fi

echo "[src-fetch] Cloning FreeBSD src tree (no proxy)..."
# Явно снимаем прокси в госте — VM SLIRP не наследует хостовые env,
# но git config может иметь proxy из предыдущих сессий.
ssh_root "env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY \
    GIT_CONFIG_NOSYSTEM=1 \
    git clone -b $REL $DEPTH https://git.freebsd.org/src.git /usr/src"

echo ""
echo "[src-fetch] Pinning commit hash to PINNED.txt..."
# /usr/src принадлежит root — читаем rev-parse как root
COMMIT=$(ssh_root "git -C /usr/src rev-parse HEAD")
echo "FreeBSD src tree pinned at commit: $COMMIT"

mkdir -p "$(dirname "$0")"/../../kernel
echo "$COMMIT" > "$(dirname "$0")"/../../kernel/PINNED.txt

echo "[src-fetch] Clone complete — commit hash written to freebsd-patches/PINNED.txt"
