# Debian 13 (trixie) ROM for the Galaxy Tab S9 Ultra — Termux build

This directory adapts the [ubuntu-galaxy-tab-s9-ultra](..) build pipeline so the
whole ROM can be produced **inside Termux** — i.e. on the Android device
itself, with **no real root**: everything runs inside a
`proot-distro` Debian container on the tablet.

## Why this works

| Upstream step | Inside Termux |
|---|---|
| rootfs bootstrap (mmdebstrap) | `--mode=fakechroot` + `--mode=proot`-less; validated: no mounts, no binfmt/qemu (arm64-native) |
| apt/dpkg inside the new rootfs | `fakechroot fakeroot chroot $rootfs …` |
| service symlinks | direct `WantedBy=` symlink helpers in `lib-rootfs.sh` |
| ext4 rootfs.img | `mkfs.ext4 -d` — no loop device / mount needed |
| reading the release image | `debugfs rdump` — no fuse/mount needed |
| Android boot images + TWRP | re-used from the official v1.2.0 release, byte-identical |

The kernel (mainline 7.2.0-rc3-dirty), the boot images and the proprietary
firmware are **distro-agnostic**, so the Debian ROM ships the exact kernel and
firmware that the Ubuntu release validated on this hardware.  Only the
root filesystem image is Debian.

## Usage (on the tablet / any arm64 device with Termux)

```sh
pkg install proot-distro
proot-distro install debian
proot-distro login debian

# inside the Debian container, as root (emulated):
apt-get update && apt-get install -y git
git clone https://github.com/agcarbajo/ubuntu-galaxy-tab-s9-ultra.git
cd ubuntu-galaxy-tab-s9-ultra

bash termux-debian/01-bootstrap-env.sh        # host build tools
bash termux-debian/02-build-rootfs.sh         # Debian trixie rootfs (long: ~10-40 min CPU)
bash termux-debian/03-integrate-device.sh     # downloads release ZIP, merges device support (long)
bash termux-debian/04-assemble-rom.sh         # rootfs.img + TWRP ZIP + SHA-256
```

The ROM lands at `/root/build/artifacts/debian-13-sm-x910-v1.0-d1.zip`.
Copy it to a microSD / OTG drive and flash it from TWRP (same procedure as the
Ubuntu release: `gts9u-split.zip` first if you want dual boot, then this ZIP).

Environment variables: `WORKDIR`, `ROOTFS_DIR`, `DEBIAN_SUITE`,
`DEBIAN_MIRROR`, `RELEASE_ZIP`, `ROOT_SLACK_MB`, `UFS_IMAGE_MAX_MB`.

## Build-environment notes (learned the hard way)

* **systemd under fakechroot** — systemd's helpers (`systemctl`,
  `systemd-tmpfiles`, `systemd-machine-id-setup`, …) link `libsystemd-shared`
  through an absolute RUNPATH into `/usr/lib/<multiarch>/systemd`.  Under
  fakechroot the *host* loader resolves that path on the host root, the
  library is invisible, and systemd's own postinst dies with "cannot open
  shared object file" (mmdebstrap's built-in workaround, #917920, targets the
  old non-multiarch `/lib/systemd` layout).  Both build scripts therefore
  export `LD_LIBRARY_PATH=$ROOTFS/usr/lib/<multiarch>/systemd`, which the
  host loader resolves against the host-visible build tree.
* **Repacking `ubuntu-gts9u-device`** — its `Depends` field is multi-line and
  contains names that are suffixes of others (`libspa-0.2-libcamera-gts9u`
  contains `libcamera-gts9u`), so line-wise `sed` leaves garbage tokens.
  `03-integrate-device.sh` rewrites the field in Python instead: collapse to
  one line, split on commas, drop the Ubuntu-only entries, rejoin.
* **Unit enablement** — the device package's `postinst` `UNITS` list is the
  source of truth; the build script re-enables exactly those units by writing
  each one's `WantedBy=` symlinks directly (`lib-rootfs.sh`).  The *build*
  host inside proot-distro has no systemd installed, so `systemctl --root=`
  cannot be used there.
* **Host has no systemd** — the proot-distro container that builds the ROM is
  not a systemd boot (no `systemctl` binary).  All unit enablement is done by
  the symlink helpers in `lib-rootfs.sh`, never with `systemctl --root`.
* **Companion postinst needs a live daemon** — `ubuntu-gts9u-companion`'s
  postinst runs `systemctl daemon-reload` unguarded, which cannot succeed with
  no PID 1 and would leave the package half-configured forever.  `03` installs
  a temporary `/usr/local/bin/systemctl` shim (exit 0 for `daemon-reload`,
  exec the real one otherwise), runs dpkg with a `PATH` that resolves the shim
  first plus the `LD_LIBRARY_PATH` above, then removes it.
* **Missing trixie packages** — the gts9u userspace needs `libqmi-glib5`,
  `libprotobuf-c1` (libssc) and `python3-dbus`, `python3-gi-cairo`
  (companion/device) which are not in the base rootfs; `03` apt-installs them
  first.  `debian.sources` must point the `-security` suite at
  `deb.debian.org/debian-security` (a shared `$mirror` URI would 404 on the
  security Release file).

## What the Debian ROM contains

* Debian 13 trixie, GNOME on Wayland (Debian's GNOME 48 stack).
* Mainline Linux 7.2.0-rc3-dirty + its initramfs + DTB from the v1.2.0
  release, untouched.
* Full device integration from the release's own packages:
  `ubuntu-gts9u-device` (repacked for Debian), `-companion`, `-hardware`,
  `-npu`, `-fingerprint-firmware`, the EL721 `libfprint`/`fprintd`/PAM trio,
  sensors (`libssc`, `hexagonrpcd`, patched `iio-sensor-proxy`), `fastfetch`.
* Firmware tree (Adreno, ADSP, Wi-Fi WCN7850/ath12k, Bluetooth, keyboard STM,
  speakers) and sensor HexagonFS tree from the release image.
* `growpart` (from cloud-guest-utils) and `pd-mapper` (from
  protection-domain-mapper) transplanted as binaries — those two packages are
  not packaged in Debian.

## What is NOT in this variant (yet)

| Feature | Why | Upstream package |
|---|---|---|
| GNOME-settings-daemon ambient-brightness patch | the patched gsd is Ubuntu 46.0; Debian ships gsd 48 | `gnome-settings-daemon` rebuild |
| Camera userspace (libcamera / PipeWire SPA / V4L2 relay) | `libspa-0.2-libcamera` pins `pipewire << 1.1`; Debian has pipewire 1.2 | `libcamera-gts9u` trio |
| System updater (Tab Companion → Updates) | branded for the Ubuntu update payload format | — |

Fingerprint userspace is installed and wired the same way as the Ubuntu
port; camera *hardware* (kernel-side V4L2) is untouched — only the userspace
that turns it into camera apps is missing.  Automatic screen brightness is
the only gnome-settings-daemon dependent feature lost.

## Caveats

* Build time: the GNOME rootfs download + install is the long pole (tens of
  minutes on-device); watch battery and thermal throttling.
* The fingerprint secure-world path needs the signed Samsung TA, which is in
  `ubuntu-gts9u-fingerprint-firmware` and installs with the same pinned
  checksums as the Ubuntu build.
* First boot after flash grows the rootfs to the whole partition (the
  released `grow-rootfs` service handles it).