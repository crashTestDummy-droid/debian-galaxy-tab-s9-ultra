#!/bin/bash
# 04-assemble-rom.sh
#
# Assemble the flashable Debian ROM ZIP for the SM-X910:
#
#   rootfs.img   Debian 13 trixie root filesystem (ext4, label UBTS9U_UFS,
#                built unprivileged with mkfs.ext4 -d -- no loop mounts)
#   + the five Android boot images from the official v1.2.0 release
#     (boot/init_boot/vendor_boot/dtbo/vbmeta)
#   + the repo's TWRP installer
#
# packed into a single ZIP via scripts/make-twrp-zip.py, exactly like the
# official Ubuntu release.  Flash from TWRP; the tablet's internal UFS gets
# the Debian rootfs, and the boot chain (kernel 7.2.0-rc3-dirty) is unchanged.
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
base=${WORKDIR:-/root/build}
rootfs=${ROOTFS_DIR:-$base/debian-rootfs}
release_dir=$base/release
out_dir=$base/artifacts
img=$base/artifacts/debian-13-sm-x910-rootfs.img
zip=$base/artifacts/debian-13-sm-x910-v1.0-d1.zip
slack_mb=${ROOT_SLACK_MB:-1152}
max_mb=${UFS_IMAGE_MAX_MB:-8192}
label=${ROOT_LABEL:-UBTS9U_UFS}
krel=7.2.0-rc3-dirty

test -d "$rootfs/etc" || { echo 'missing rootfs' >&2; exit 1; }
test -f "$release_dir/boot.img" || { echo 'missing release bundle' >&2; exit 1; }
mkdir -p "$out_dir"

# ---------------------------------------------------------------------------
# Boot metadata (what the official image carries; kept for parity)
# ---------------------------------------------------------------------------
cat > "$rootfs/boot/BUILD-METADATA.txt" <<EOF
kernel_release=$krel
root_label=$label
os=debian-13-trixie
install_target=internal UFS, linuxroot if present, else userdata
kernel_image_sha256=$(sha256sum "$release_dir/boot.img" | cut -d' ' -f1)
kernel_dtb_sha256=$(sha256sum "$release_dir/vendor_boot.img" | cut -d' ' -f1)
initramfs_sha256=$(sha256sum "$rootfs/boot/initrd.img-$krel" | cut -d' ' -f1)
built=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

# ---------------------------------------------------------------------------
# ext4 root filesystem image (no mounting, no loop device)
# ---------------------------------------------------------------------------
content_mb=$(du -sm --apparent-size "$rootfs" | cut -f1)
image_mb=$((content_mb + slack_mb))
echo "image: ${image_mb} MiB (content ${content_mb}, slack ${slack_mb})"
if [ "$image_mb" -gt "$max_mb" ]; then
	echo "image exceeds the ${max_mb} MiB budget; raise UFS_IMAGE_MAX_MB or trim" >&2
	exit 1
fi

rm -f "$img"
truncate -s "${image_mb}M" "$img"
# -E resize lets first boot grow this filesystem to the whole userdata
# partition online; -m 1 avoids wasting 5% on a 939 GiB partition.
mkfs.ext4 -q -F -L "$label" -e remount-ro -m 1 \
	-E resize=268435456 -d "$rootfs" "$img"
e2fsck -fp "$img" >/dev/null || {
	rc=$?
	[ "$rc" -le 1 ] || { echo "e2fsck rejected the image ($rc)" >&2; exit 1; }
}

echo '=== rootfs image ==='
stat -c '%n %s bytes' "$img"

# ---------------------------------------------------------------------------
# TWRP ZIP
# ---------------------------------------------------------------------------
echo '=== packaging the TWRP installer ZIP ==='
python3 "$repo/scripts/make-twrp-zip.py" \
	"$release_dir" \
	"$zip" \
	--rootfs "$img" \
	--label "Debian 13 (trixie) for SM-X910 gts9uwifi, kernel 7.2.0-rc3-dirty"

echo '=== SHA-256 ==='
sha256sum "$img" "$zip"
cat > "$out_dir/MANIFEST.txt" <<EOF
debian-13-sm-x910 ROM for Samsung Galaxy Tab S9 Ultra (SM-X910, gts9uwifi)
built:      $(date -u +%Y-%m-%dT%H:%M:%SZ)
debian:     trixie (13.7) arm64, GNOME, Wayland
kernel:     mainline 7.2.0-rc3-dirty (from the official v1.2.0 release)
$(sha256sum "$img" "$zip" | sed 's#^#  #')
install:    flash debian-13-sm-x910-v1.0-d1.zip from TWRP
EOF
echo "ROM is at: $zip"