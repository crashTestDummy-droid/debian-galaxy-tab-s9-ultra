#!/bin/bash
# 01-bootstrap-env.sh
#
# Install the host tools needed to build a Debian ROM for the SM-X910 inside
# Termux (proot-distro Debian, no real root).  Run this once inside the
# proot-distro Debian container:
#
#   proot-distro login debian
#   bash termux-debian/01-bootstrap-env.sh
#
# Everything here is compiled for arm64 and runs natively: no qemu/binfmt,
# no mount, no loop devices.  "root" is emulated by proot.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

echo '=== 1/4 updating package lists ==='
apt-get update -qq

echo '=== 2/4 installing build tools ==='
apt-get install -y -qq --no-install-recommends \
	mmdebstrap \
	fakechroot \
	fakeroot \
	e2fsprogs \
	e2tools \
	python3 \
	python3-pycryptodome \
	cpio \
	lz4 \
	zstd \
	xz-utils \
	unzip \
	zip \
	curl \
	ca-certificates \
	file \
	git \
	rsync

echo '=== 3/4 verifying the toolchain ==='
need() { command -v "$1" >/dev/null 2>&1 && echo "OK    $1" || { echo "MISS  $1"; missing=1; }; }
missing=0
need mmdebstrap
need fakechroot
need fakeroot
need debugfs
need mkfs.ext4
need unzip
need python3
[ "$(uname -m)" = aarch64 ] || { echo 'not running natively on arm64!' >&2; missing=1; }
[ "$missing" = 0 ] || { echo 'missing dependencies' >&2; exit 1; }

echo '=== 4/4 disk check ==='
need_space=$((64 * 1024))   # 64 GiB is a comfortable floor for the whole build
avail_kb=$(df -Pk "$HOME" | awk 'NR==2{print $4}')
echo "available: $((avail_kb / 1024 / 1024)) GiB"
[ "$avail_kb" -gt "$need_space" ] || {
	echo 'less than 64 GiB available; the rootfs+image will be several GiB' >&2
}

echo 'All Termux build dependencies are present.'