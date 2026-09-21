# lib-rootfs.sh -- shared helpers for the Termux (proot, no real root) build.
# Source from 02/03.  No systemd is installed on the *build* host, so the
# systemctl --root= idiom is replaced by directly writing the enablement
# symlinks that `systemctl enable` would create (read the unit's own
# [Install] WantedBy= lines -- every unit this pipeline deals with uses
# WantedBy=, none use Alias=/RequiredBy=).

# enable_root UNIT  -- create <rootfs>/etc/systemd/system/<target>.wants/UNIT
# for each WantedBy= target the unit declares.
enable_root() {
	local unit=$1 target
	for target in $(sed -n 's/^WantedBy=//p' "$rootfs/usr/lib/systemd/system/$unit" 2>/dev/null); do
		mkdir -p "$rootfs/etc/systemd/system/$target.wants"
		ln -sf "/usr/lib/systemd/system/$unit" \
			"$rootfs/etc/systemd/system/$target.wants/$unit"
	done
}

# disable_root UNIT -- remove every <target>.wants/UNIT symlink for it.
disable_root() {
	local unit=$1
	rm -f "$rootfs"/etc/systemd/system/*.wants/"$unit" 2>/dev/null || true
}

# sanitize_rootfs -- fakechroot/proot builds create absolute symlinks whose
# targets embed the *host* build path (e.g. update-alternatives -> /root/build/
# debian-rootfs/usr/bin/mawk, gdm3's display-manager.service -> /root/build/
# .../lib/systemd/system/gdm3.service).  On the device those resolve to
# nothing.  Rewrite every symlink target that starts with the build dir to the
# matching root-relative path (strip the prefix, keep the leading slash).
sanitize_rootfs() {
	local prefix=${1:-$rootfs} link target
	find "$rootfs" -xdev -type l -print 2>/dev/null | while IFS= read -r link; do
		target=$(readlink "$link" 2>/dev/null) || continue
		case "$target" in
			"$prefix/"*)
				ln -sfn "/${target#"$prefix"/}" "$link" ;;
		esac
	done
}