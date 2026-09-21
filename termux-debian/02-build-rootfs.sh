#!/bin/bash
# 02-build-rootfs.sh
#
# Build the Debian 13 (trixie) arm64 root filesystem for the SM-X910 inside
# Termux, using mmdebstrap in fakechroot mode (no real root, no mounts).
#
# Same contract as scripts/build-ubuntu-rootfs.sh: the result is a directory
# tree, not an image.  Base system + GNOME desktop on Wayland, with no distro
# kernel (the mainline 7.2.0-rc3 kernel comes from the released bundle).
#
# Usage: bash termux-debian/02-build-rootfs.sh [profile]
#   profile: minimal | desktop (default: desktop)
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

repo=$(cd "$(dirname "$0")/.." && pwd)
base=${WORKDIR:-/root/build}
rootfs=${ROOTFS_DIR:-$base/debian-rootfs}
profile=${1:-desktop}
suite=${DEBIAN_SUITE:-trixie}
mirror=${DEBIAN_MIRROR:-https://deb.debian.org/debian}
hostname=debian-gts9uwifi
locale=${GTS9U_LOCALE:-en_US.UTF-8}
timezone=${GTS9U_TIMEZONE:-UTC}
keymap=${GTS9U_KEYMAP:-us}
ma=${GTS9U_MULTIARCH:-aarch64-linux-gnu}

# systemd's helpers (systemctl, systemd-tmpfiles, systemd-machine-id-setup,
# ...) link against libsystemd-shared-257.so via an absolute RUNPATH into
# /usr/lib/<multiarch>/systemd.  Under fakechroot the host ld.so resolves
# that path on the *host* root, so the library is invisible and systemd's own
# postinst dies with "cannot open shared object file" (mmdebstrap has a
# partial workaround for this, #917920, but it targets the old non-multiarch
# /lib/systemd layout).  Point the loader straight at the real files; the
# directory is a valid host path because we build into a host-visible tree.
libdir=$rootfs/usr/lib/$ma/systemd
export LD_LIBRARY_PATH="$libdir${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

command -v mmdebstrap >/dev/null || { echo 'run 01-bootstrap-env.sh first' >&2; exit 1; }

# arm64-native build: no qemu/binfmt is needed, so the Ubuntu script's
# /proc/sys/fs/binfmt_misc/qemu-aarch64 check is intentionally skipped.

case "$rootfs" in
	"$base"/*) ;;
	*) echo "refusing to build outside $base: $rootfs" >&2; exit 1 ;;
esac

# ---------------------------------------------------------------------------
# Package sets (Debian names; trixie)
# ---------------------------------------------------------------------------

base_packages='
systemd,systemd-sysv,systemd-resolved,udev,dbus,
initramfs-tools,busybox,
e2fsprogs,dosfstools,parted,gdisk,
zstd,xz-utils,lz4,
sudo,locales,tzdata,console-setup,keyboard-configuration,
apparmor,apparmor-utils,
netplan.io,network-manager,wpasupplicant,
openssh-server,avahi-daemon,
iputils-ping,curl,wget,ca-certificates,
nano,less,htop,rsync,unzip,acl,
usbutils,pciutils,ethtool,evtest,i2c-tools,v4l-utils,
strace,tree,
python3,qrtr-tools,libqrtr-glib0,adduser,polkitd
'

desktop_packages='
gnome-shell,gdm3,gnome-session,gnome-control-center,gnome-initial-setup,
gnome-terminal,gnome-console,nautilus,gnome-text-editor,gnome-snapshot,
gstreamer1.0-gl,
mutter,xdg-desktop-portal-gnome,xdg-user-dirs,
gnome-keyring,libpam-gnome-keyring,
mesa-utils,mesa-vulkan-drivers,libgl1-mesa-dri,vulkan-tools,
libdrm-tests,edid-decode,
pipewire,pipewire-pulse,pipewire-audio,wireplumber,pulseaudio-utils,
libspa-0.2-bluetooth,bluez,alsa-ucm-conf,alsa-utils,
upower,power-profiles-daemon,
fonts-noto-color-emoji,gnome-software,
firefox-esr
'

packages=$(printf '%s' "$base_packages" | tr -d ' \n')
if [ "$profile" = desktop ]; then
	packages="$packages,$(printf '%s' "$desktop_packages" | tr -d ' \n')"
fi

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------

mkdir -p "$base"
if [ -d "$rootfs/etc" ] && [ "${RESUME_ROOTFS:-0}" != 1 ]; then
	echo "a rootfs already exists at $rootfs; delete it or set RESUME_ROOTFS=1" >&2
	exit 1
fi

if [ -d "$rootfs/etc" ] && [ ! -x "$rootfs/usr/bin/dpkg" ]; then
	rm -rf -- "$rootfs"
fi

if [ -d "$rootfs/etc" ]; then
	echo "resuming with existing rootfs: $rootfs"
else
	echo "building Debian $suite ($profile) arm64 -> $rootfs"
	mmdebstrap \
		--mode=fakechroot \
		--architecture=arm64 \
		--variant=important \
		--components='main,contrib,non-free-firmware' \
		--include="$packages" \
		--verbose \
		"$suite" \
		"$rootfs" \
		"$mirror"
fi

# ---------------------------------------------------------------------------
# Base configuration (host-side file writes; no chroot needed)
# ---------------------------------------------------------------------------

echo "=== configuring the base system ==="
echo "$hostname" > "$rootfs/etc/hostname"
cat > "$rootfs/etc/hosts" <<EOF
127.0.0.1	localhost
127.0.1.1	$hostname
::1		localhost ip6-localhost ip6-loopback
fe00::0		ip6-localnet
ff00::0		ip6-mcastprefix
ff02::1		ip6-allnodes
ff02::2		ip6-allrouters
EOF

echo 'LANG='"$locale" > "$rootfs/etc/default/locale"
echo 'en_US.UTF-8 UTF-8' > "$rootfs/etc/locale.gen"
ln -sf "/usr/share/zoneinfo/$timezone" "$rootfs/etc/localtime"
echo "$timezone" > "$rootfs/etc/timezone"
cat > "$rootfs/etc/default/keyboard" <<EOF
XKBMODEL="pc105"
XKBLAYOUT="$keymap"
XKBVARIANT=""
XKBOPTIONS=""
BACKSPACE="guess"
EOF

# The mainline kernel mounts the root filesystem by label (see
# configs/vendor_boot/cmdline.txt).  The grow script then expands it to the
# whole partition on first boot.
cat > "$rootfs/etc/fstab" <<'EOF'
LABEL=UBTS9U_UFS	/	ext4	defaults,noatime,errors=remount-ro	0 1
EOF

# Same initramfs contract as the Ubuntu port; the shipped initramfs is the
# release build (see 03-integrate-device.sh), so this is for parity/rebuilds.
cat > "$rootfs/etc/initramfs-tools/initramfs.conf" <<'EOF'
MODULES=most
BUSYBOX=y
KEYMAP=n
COMPRESS=lz4
COMPRESSLEVEL=9
DEVICE=
NFSROOT=auto
RUNSIZE=10%
EOF

mkdir -p "$rootfs/etc/netplan"
cat > "$rootfs/etc/netplan/01-network-manager-all.yaml" <<EOF
network:
  version: 2
  renderer: NetworkManager
EOF
chmod 0600 "$rootfs/etc/netplan/01-network-manager-all.yaml"

cat > "$rootfs/etc/apt/sources.list.d/debian.sources" <<EOF
Types: deb
URIs: $mirror
Suites: $suite $suite-updates $suite-backports
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: ${DEBIAN_SECURITY_MIRROR:-https://deb.debian.org/debian-security}
Suites: $suite-security
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
# debian.sources already covers every component/suite; the extra flat
# sources.list entry would only duplicate these (and confuse the resolver).
rm -f "$rootfs/etc/apt/sources.list"

mkdir -p "$rootfs/etc/ssh/sshd_config.d"
cat > "$rootfs/etc/ssh/sshd_config.d/10-gts9uwifi.conf" <<'EOF'
PasswordAuthentication yes
PermitRootLogin no
EOF

mkdir -p "$rootfs/etc/systemd/journald.conf.d"
cat > "$rootfs/etc/systemd/journald.conf.d/10-gts9uwifi-persistent.conf" <<'EOF'
[Journal]
Storage=persistent
SystemMaxUse=256M
EOF

# No apt-installed kernel: this port boots the mainline kernel from the
# Android boot partition, and its modules are staged by the ROM pipeline.
mkdir -p "$rootfs/etc/apt/preferences.d"
cat > "$rootfs/etc/apt/preferences.d/no-distro-kernel" <<'EOF'
Package: linux-image-* linux-headers-* linux-generic*
Pin: release *
Pin-Priority: -1
EOF

# ---------------------------------------------------------------------------
# Chroot-side configuration (fakechroot: path-rewriting, no real chroot)
# ---------------------------------------------------------------------------

in_chroot() {
	# No `env -i` (see 03): it would drop fakechroot's path-rewriting
	# variables and silently run against the host container.
	fakechroot fakeroot chroot "$rootfs" "$@"
}

echo "=== chroot: locales, root lock, gdm first-boot wizard ==="
in_chroot locale-gen >/dev/null 2>&1 || true
in_chroot update-locale "LANG=$locale" >/dev/null 2>&1 || true

in_chroot passwd -l root

# No account ships with the image: GDM runs gnome-initial-setup for the
# owner-created account, same first-boot experience as the Ubuntu port.
if ! grep -q '^InitialSetupEnable=true' "$rootfs/etc/gdm3/custom.conf" 2>/dev/null; then
	if grep -q '^\[daemon\]' "$rootfs/etc/gdm3/custom.conf" 2>/dev/null; then
		sed -i '/^\[daemon\]/a InitialSetupEnable=true' "$rootfs/etc/gdm3/custom.conf"
	else
		printf '[daemon]\nInitialSetupEnable=true\n' >> "$rootfs/etc/gdm3/custom.conf"
	fi
fi

echo "=== enabling services (WantedBy symlinks) ==="
# shellcheck source=lib-rootfs.sh
source "$(dirname "$0")/lib-rootfs.sh"
enable_root ssh.service
enable_root NetworkManager.service
enable_root systemd-timesyncd.service

# Replace fakechroot's /root/build/...-anchored symlink targets (see
# lib-rootfs.sh) so they resolve on the device.
sanitize_rootfs

cat > "$rootfs/usr/lib/gts9u-release.json" <<EOF
{
  "os": "debian", "suite": "$suite", "device": "gts9uwifi",
  "kernel_release": "7.2.0-rc3-dirty"
}
EOF

echo '=== rootfs summary ==='
du -sh "$rootfs"
in_chroot dpkg-query -W -f '${binary:Package}\n' | wc -l | sed 's/^/packages installed: /'