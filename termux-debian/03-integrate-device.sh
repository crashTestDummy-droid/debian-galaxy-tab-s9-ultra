#!/bin/bash
# 03-integrate-device.sh
#
# Merge the SM-X910 integration into the freshly built Debian rootfs:
#
#   * kernel 7.2.0-rc3 modules (incl. ath12k, fingerprint and camera bits),
#     the proprietary firmware tree, the sensor HexagonFS tree, the kernel
#     config, the shipped initramfs and the DTB -- all extracted from the
#     official v1.2.0 release rootfs.img (the kernel/firmware are distro
#     agnostic and already validated on this hardware);
#   * the gts9u userspace packages (device, companion, hardware, sensors,
#     fingerprint, NPU, fastfetch) as the .debs published with that release;
#   * a locally repacked ubuntu-gts9u-device that drops
#     cloud-guest-utils/protection-domain-mapper (not packaged in Debian) and
#     the camera trio (libcamera-gts9u + libspa-0.2-libcamera + v4l2-relayd,
#     which pin pipewire < 1.1, while Debian trixie ships pipewire 1.2).
#
# Not included in the Debian ROM for now (documented in README.md):
#   * gnome-settings-daemon 46 rebuild (Ubuntu-blue, patched for ambient
#     brightness) -- Debian keeps its GNOME 48 gsd, so automatic screen
#     brightness is unavailable in this variant;
#   * camera userspace (see above).
#
# This is a one-way integration into a dedicated rootfs directory.  Nothing
# here flashes a device.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

repo=$(cd "$(dirname "$0")/.." && pwd)
base=${WORKDIR:-/root/build}
rootfs=${ROOTFS_DIR:-$base/debian-rootfs}
release_dir=$base/release
zip_path=${RELEASE_ZIP:-$base/release-v1.2.0.zip}
release_sha256=1dc47f81196284b26931c2fd91ae20c662404dd4659f730f8dd463006acab307
krel=7.2.0-rc3-dirty
ma=${GTS9U_MULTIARCH:-aarch64-linux-gnu}
libdir=$rootfs/usr/lib/$ma/systemd
# See 02-build-rootfs.sh: systemd helpers need LD_LIBRARY_PATH to find
# libsystemd-shared under fakechroot (absolute RUNPATH, host loader).
export LD_LIBRARY_PATH="$libdir${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

test -d "$rootfs/etc" || { echo "missing rootfs: run 02-build-rootfs.sh first" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1. Released bundle
# ---------------------------------------------------------------------------
if [ ! -f "$zip_path" ]; then
	echo "downloading the official v1.2.0 release ZIP"
	curl -fL -o "$zip_path" \
		https://github.com/agcarbajo/ubuntu-galaxy-tab-s9-ultra/releases/download/v1.2.0/ubuntu-24.04-sm-x910-v1.2.0.zip
fi
echo "verifying $zip_path"
echo "$release_sha256  $zip_path" | sha256sum -c - >/dev/null || {
	echo 'release ZIP failed its SHA-256 check' >&2; exit 1
}

if [ ! -f "$release_dir/rootfs.img" ]; then
	mkdir -p "$release_dir"
	unzip -o -q "$zip_path" -d "$release_dir"
fi

# ---------------------------------------------------------------------------
# 2. Transplants from the release rootfs image (debugfs, no mount needed)
# ---------------------------------------------------------------------------
img=$release_dir/rootfs.img
echo '=== transplanting kernel modules, firmware and helpers ==='
mkdir -p "$rootfs/usr/lib/modules"
debugfs -R "rdump /usr/lib/modules/$krel $rootfs/usr/lib/modules" "$img" >/dev/null 2>&1

mkdir -p "$rootfs/usr/lib/firmware"
debugfs -R 'rdump /usr/lib/firmware '$rootfs'/usr/lib/firmware' "$img" >/dev/null 2>&1

mkdir -p "$rootfs/usr/share/qcom"
debugfs -R 'rdump /usr/share/qcom '$rootfs'/usr/share/qcom' "$img" >/dev/null 2>&1

mkdir -p "$rootfs/boot"
for f in "config-$krel" "initrd.img-$krel" "sm8550-samsung-gts9uwifi.dtb"; do
	debugfs -R "rdump /boot/$f $rootfs/boot" "$img" >/dev/null 2>&1
done

# cloud-guest-utils (growpart) and protection-domain-mapper are not packaged
# in Debian: transplant the binaries from the release image.  pd-mapper links
# against libqrtr-glib, which Debian ships; growpart is a shell script using
# sfdisk from util-linux.  (rdump would drop the directory and leave files at
# the image root, so use `dump` with explicit destinations instead.)
mkdir -p "$rootfs/usr/bin"
for f in pd-mapper growpart; do
	debugfs -R "dump /usr/bin/$f $rootfs/usr/bin/$f" "$img" >/dev/null 2>&1 \
		|| { echo "transplant failed: /usr/bin/$f" >&2; exit 1; }
done
chmod 0755 "$rootfs/usr/bin/pd-mapper" "$rootfs/usr/bin/growpart"

test -d "$rootfs/usr/lib/modules/$krel" || { echo 'module transplant failed' >&2; exit 1; }
echo "modules: $(find "$rootfs/usr/lib/modules/$krel" -name '*.ko*' | wc -l) kernel objects"

# ---------------------------------------------------------------------------
# 3. Repack ubuntu-gts9u-device for Debian
# ---------------------------------------------------------------------------
dev_deb=$(ls "$release_dir"/UPDATE/debs/ubuntu-gts9u-device_*.deb | head -1)
stage=$base/deb-device-repack
rm -rf -- "$stage"
mkdir -p "$stage"
dpkg-deb -x "$dev_deb" "$stage"
dpkg-deb -e "$dev_deb" "$stage/DEBIAN"
# Drop the Ubuntu-only/release-pinned dependencies from the Depends field.
# Naive sed breaks on names that are suffixes of others (libspa-0.2-libcamera
# contains libcamera-gts9u), so do the field rewrite in Python: collapse the
# multi-line field, split on commas, filter, rejoin as one line.
python3 - "$stage/DEBIAN/control" <<'PY'
import re, sys

control = sys.argv[1]
text = open(control).read()

field = re.search(r'^Depends:(.*?)(?=^\S|\Z)', text, re.S | re.M)
if not field:
    sys.exit('no Depends field in control')
# Split the (possibly wrapped) field into package clauses.
clauses = []
for raw in re.split(r',\s*', ' '.join(field.group(1).split())):
    pkg = raw.split()[0] if raw.split() else ''
    if pkg and pkg not in {
        'cloud-guest-utils', 'protection-domain-mapper',
        'libcamera-gts9u', 'libspa-0.2-libcamera-gts9u', 'v4l2-relayd-gts9u',
    }:
        clauses.append(raw)

new_field = 'Depends: ' + ', '.join(clauses) + '\n'
text = text[: field.start()] + new_field + text[field.end():]
text = re.sub(r'^Version: .*$', 'Version: 2.53~debian1', text, flags=re.M)
open(control, 'w').write(text)
PY
repacked=$base/custom-debs/ubuntu-gts9u-device_2.53~debian1_arm64.deb
mkdir -p "$(dirname "$repacked")"
dpkg-deb --build -Zxz "$stage" "$repacked" >/dev/null
echo "repacked $repacked"
echo "new Depends line:"
grep '^Depends:' "$stage/DEBIAN/control"

# ---------------------------------------------------------------------------
# 4. Install the gts9u userspace packages in one dpkg transaction
# ---------------------------------------------------------------------------
in_chroot() {
	# No `env -i`: stripping the environment kills fakechroot's path
	# rewriting (FAKECHROOT_* vars are dropped) and dpkg would silently
	# operate on the *host* container instead of this rootfs.
	fakechroot fakeroot chroot "$rootfs" "$@"
}

custom_debs=$base/custom-debs
mkdir -p "$custom_debs"
for deb in libssc_*.deb hexagonrpcd_*.deb iio-sensor-proxy_*.deb \
	fprintd_*.deb libpam-fprintd_*.deb libfprint-2-2_*.deb \
	ubuntu-gts9u-fingerprint-firmware_*.deb fastfetch_*.deb \
	ubuntu-gts9u-hardware_*.deb ubuntu-gts9u-companion_*.deb \
	ubuntu-gts9u-npu_*.deb; do
	src=$(ls "$release_dir"/UPDATE/debs/$deb 2>/dev/null | head -1 || true)
	[ -n "$src" ] && cp "$src" "$custom_debs/"
done

echo '=== installing gts9u packages (dpkg) ==='
# Some Debian packages required by the gts9u userspace are not in the base
# rootfs (libssc's libqmi-glib5/libprotobuf-c1, companion/device
# python3-dbus/python3-gi-cairo -- all plain trixie packages).  Install them
# first so the plain dpkg -i has no dependency holes.
in_chroot apt-get update >/dev/null 2>&1 || in_chroot apt-get update
in_chroot apt-get install -y --no-install-recommends \
	libqmi-glib5 libprotobuf-c1 python3-dbus python3-gi-cairo \
	>/dev/null 2>&1 || in_chroot apt-get install -y \
	libqmi-glib5 libprotobuf-c1 python3-dbus python3-gi-cairo

# fakechroot path-rewrites every absolute path into the fake root, so dpkg
# inside the chroot cannot see the host-visible custom-debs dir.  Stage the
# .debs inside the rootfs (/tmp is a normal, non-excluded path) and install
# from there, then clean up.
deb_stage=$rootfs/tmp/gts9u-debs
rm -rf "$deb_stage"
mkdir -p "$deb_stage"
cp "$custom_debs"/*.deb "$deb_stage"/
# The host shell globs against the *host* filesystem; translate the staged
# paths into their fake-root equivalents (/tmp/gts9u-debs/...) for dpkg.
fake_debs=()
for deb in "$deb_stage"/*.deb; do
	fake_debs+=( "/tmp/gts9u-debs/${deb##*/}" )
done

# ubuntu-gts9u-companion's postinst runs `systemctl daemon-reload` unguarded;
# there is no PID 1 to talk to in the fakechroot build, so it aborts the
# postinst (companion would stay half-configured).  Shim `daemon-reload` to
# success for the duration of the install (dpkg sanitises the maintainer
# script environment, so feed it a PATH that resolves the shim first).
shim=$rootfs/usr/local/bin/systemctl
mkdir -p "$rootfs/usr/local/bin"
cat > "$shim" <<'EOF'
#!/bin/sh
if [ "$1" = "daemon-reload" ]; then
	exit 0
fi
exec /usr/bin/systemctl "$@"
EOF
chmod 0755 "$shim"

if ! PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
	LD_LIBRARY_PATH="$libdir" in_chroot dpkg -i "${fake_debs[@]}"; then
	PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
	LD_LIBRARY_PATH="$libdir" in_chroot dpkg -i \
		--force-depends --force-overwrite "${fake_debs[@]}"
fi
# Configuring again with a live path brings anything the forced run skipped
# (e.g. companion) to a fully configured state.
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
	LD_LIBRARY_PATH="$libdir" in_chroot dpkg --configure -a || true
rm -rf "$deb_stage"
rm -f "$shim"
rmdir "$rootfs/usr/local/bin" 2>/dev/null || true

echo '=== post-install consistency ==='
in_chroot apt-get check >/dev/null 2>&1 || {
	echo 'apt-get check failed; investigating' >&2
	in_chroot apt-get check >&2 || true
}

# The device package enables its units in postinst (systemctl inside the
# fakechroot may or may not write the symlinks); guarantee them from the host
# by writing the WantedBy= symlinks directly (the build host has no systemd
# installed, so no systemctl --root).  This mirrors the postinst UNITS list;
# each unit's own [Install] section decides the target, e.g. cpu-boost ->
# graphical.target, zram -> basic.target.
# shellcheck source=lib-rootfs.sh
source "$(dirname "$0")/lib-rootfs.sh"
for unit in \
	ubuntu-gts9u-cpu-boost.service \
	ubuntu-gts9u-panel-coldboot-recover.service \
	ubuntu-gts9u-adsp-boot.service \
	ubuntu-gts9u-sensor-registry.service \
	ubuntu-gts9u-powerkey.service \
	ubuntu-gts9u-bluetooth-address.service \
	ubuntu-gts9u-sensors-resume.service \
	ubuntu-gts9u-pogo-firmware.service \
	ubuntu-gts9u-desktop-user.service \
	ubuntu-gts9u-desktop-user.path \
	ubuntu-gts9u-grow-rootfs.service \
	ubuntu-gts9u-zram.service \
	ubuntu-gts9u-swapfile.service \
	ubuntu-gts9u-chromium-desktops.service \
	ubuntu-gts9u-chromium-desktops.path \
	ubuntu-gts9u-fingerprint-ui.service \
	ubuntu-gts9u-fingerprint-secure.service \
	tab-companion-spen-pairing.service; do
	enable_root "$unit"
done
# The camera relays are not part of the Debian v1 ROM (no libcamera userspace).
disable_root ubuntu-gts9u-camera-relays.service
# Companion's --global user unit (systemctl --global enable equivalent).
mkdir -p "$rootfs/etc/systemd/user/graphical-session.target.wants"
ln -sf /usr/lib/systemd/user/tab-companion-haptics-enable.service \
	"$rootfs/etc/systemd/user/graphical-session.target.wants/tab-companion-haptics-enable.service"

# Repoint any absolute symlinks whose target embeds the host build path
# (update-alternatives, gdm3's display-manager.service, ...) to root-relative
# paths so they resolve on the device.
sanitize_rootfs

echo '=== integration summary ==='
in_chroot dpkg-query -W -f '${binary:Package} ${Version}\n' \
	fprintd libpam-fprintd libfprint-2-2 iio-sensor-proxy \
	libssc hexagonrpcd fastfetch \
	ubuntu-gts9u-device ubuntu-gts9u-companion ubuntu-gts9u-hardware \
	ubuntu-gts9u-npu ubuntu-gts9u-fingerprint-firmware 2>/dev/null || true
ls -la "$rootfs/usr/bin/growpart" "$rootfs/usr/bin/pd-mapper" 2>/dev/null || true
du -sh "$rootfs"