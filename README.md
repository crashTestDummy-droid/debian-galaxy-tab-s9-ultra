# ATTENTION: THIS WAS VIBE CODED USING AI AGENTS, INSTALL IT AT YOUR OWN RISK AND DISCRETION.

## Debian 13 (trixie) for the Samsung Galaxy Tab S9 Ultra (SM-X910 / gts9uwifi)

A **Debian** ROM for the Galaxy Tab S9 Ultra, built from this repository.

This is a Debian variant of the
[ubuntu-galaxy-tab-s9-ultra](https://github.com/agcarbajo/ubuntu-galaxy-tab-s9-ultra)
project (the validated Ubuntu 24.04 port for this tablet).  It installs a
Debian 13 **trixie** root filesystem — GNOME 48 on Wayland, 937 packages from
the Debian archive — while reusing the port's **kernel and boot chain
byte-identically**: mainline Linux `7.2.0-rc3-dirty`, its initramfs, DTB and
the five flashable boot images come untouched from the official v1.2.0
release, so the hardware bring-up (display, touch, S Pen, Wi-Fi, Bluetooth,
speakers, sensors, fingerprint) is exactly what the Ubuntu port validated.

**Version:** `1.0-d1-debian` — see [VERSION](VERSION).
**Base:** upstream `ubuntu-galaxy-tab-s9-ultra` v1.2.0 (kernel `7.2.0-rc3-dirty`).

---

## What you get

| Component | Detail |
|---|---|
| OS | Debian 13 trixie (arm64), GNOME 48 on Wayland, systemd |
| Kernel | Mainline `7.2.0-rc3-dirty` (from the official v1.2.0 release) |
| Boot chain | `boot`, `init_boot`, `vendor_boot`, `dtbo`, `vbmeta` — byte-identical to v1.2.0 |
| Firmware | Adreno, ADSP, Wi-Fi (WCN7850/ath12k), Bluetooth, keyboard STM, speakers, sensor HexagonFS — from the release, installed at `/usr/lib/firmware` and `/usr/share/qcom` |
| Device integration | `ubuntu-gts9u-device` (repacked for Debian), `-companion`, `-hardware`, `-npu`, fingerprint (EL721 `libfprint`/`fprintd`/PAM), sensors (`libssc`, `hexagonrpcd`, `iio-sensor-proxy`), `fastfetch` |
| Install target | internal UFS — `linuxroot` if the dual-boot split is present, otherwise `userdata` |

### Working out of the box

- Display, touch, S Pen and the pogo keyboard
- Wi-Fi and Bluetooth (NetworkManager, ath12k firmware)
- Speakers and audio (ALSA UCM + device mixer profiles)
- Sensors: auto-rotate and light sensing via `iio-sensor-proxy` + Hexagon DSP
- Fingerprint login (EL721) with the signed Samsung TA
- S Pen dock pairing and haptics (`tab-companion`)
- Dual boot with Android (same split + Dualboot app as the Ubuntu port)
- Suspend/resume, zram/swap, CPU boost, and rootfs growth on first boot
- SSH (password auth, root login disabled)

### Not in this variant (yet)

- **Camera userspace** (libcamera / PipeWire relays) — pins Ubuntu's pipewire
  1.0; Debian ships 1.2. See `termux-debian/README.md`.
- **Ambient-brightness in GNOME settings daemon** — the patched gsd is
  Ubuntu 46; Debian ships gsd 48.
- **Tab Companion system updater** — targets the Ubuntu payload format.

---

## Install

1. **TWRP** on the tablet (same recovery as the Ubuntu port).
2. Optional (dual boot): flash `gts9u-split.zip` first to create the
   `linuxroot` partition beside Android, then install the
   `Dualboot` Android app. Skip this to replace `userdata` entirely.
3. Flash this ROM's ZIP (product of `04-assemble-rom.sh`, attached to the
   GitHub Release). The installer detects `linuxroot` and writes the Debian
   root filesystem there, seeds the dual-boot sets, and never touches
   `vbmeta` unless it is safe to do so.
4. First boot grows the root filesystem to the whole partition, then runs
   GNOME's initial setup to create your first (admin) user.
5. Verify against the release's SHA-256 checksums.

Kernel modules for `7.2.0-rc3-dirty` ship inside the ROM at
`/usr/lib/modules/` — do **not** `apt install linux-image-*`, which would
mismatch the boot chain.

---

## Building it

Everything can be built **on the tablet itself** in a Termux
`proot-distro` Debian container — no PC, no root, no mounts:

```sh
# inside proot-distro Debian, as root:
apt-get update && apt-get install -y git
git clone <this repository>
cd <this repository>
bash termux-debian/01-bootstrap-env.sh
bash termux-debian/02-build-rootfs.sh
bash termux-debian/03-integrate-device.sh   # pulls the official v1.2.0 release
bash termux-debian/04-assemble-rom.sh
```

The ROM lands in `build/artifacts/`. See
[`termux-debian/README.md`](termux-debian/README.md) for full detail.

The Debian rootfs is assembled from the Debian archive; the kernel, boot
images, firmware and the gts9u userspace packages are reused from the official
v1.2.0 release (which is distro-agnostic for those parts). No kernel
compilation, signing, or proprietary-toolchain step is required to reproduce
a build.

---

## Repository layout

| Path | What it is |
|---|---|
| `termux-debian/` | **This project's pipeline** — Termux/no-root build scripts and README |
| `configs/twrp/` | TWRP installer (rebranded for Debian) and the dual-boot split script |
| `scripts/` | Packaging and release tooling (inherited from the port) |
| `packaging/`, `kernel/`, `android/` | Device integration sources (inherited; the `.deb` binaries are reused from the release) |
| `docs/` | Hardware/tooling documentation — **inherited from the Ubuntu port**, so it may reference Ubuntu specifics |
| `artifacts/` | Build products (regenerable; never committed) |

## Versioning

- `VERSION` = `1.0-d1-debian` identifies **this repository's** ROM release.
- The kernel and boot chain are the upstream v1.2.0 release's; `VERSION` does
  not imply an upstream version.

## License and credits

MIT — see [LICENSE](LICENSE). Derivative of
[agcarbajo/ubuntu-galaxy-tab-s9-ultra](https://github.com/agcarbajo/ubuntu-galaxy-tab-s9-ultra)
(MIT), whose v1.2.0 release contributes the kernel, boot images, firmware and
device-package binaries byte-identically; the TWRP installer traces its MIT
lineage to the postmarketOS gts9uwifi port.  This project is not affiliated
with Samsung or with the upstream authors.
