# AOSP 17 for the Moto G7 Play (`channel`)

Unofficial AOSP Android 17 port for the Motorola Moto G7 Play (codename **`channel`**,
Qualcomm **SDM632 / msm8953**, Adreno 506, inline Linux **4.9** kernel). Open Mesa/Freedreno
GL, SDE fbdev composer, eBPF-1:1 backport on the 4.9 kernel. Boots to home; GPU / Wi-Fi / BT /
camera / flashlight work.

## What you need
- A Linux host with the [AOSP build prerequisites](https://source.android.com/setup/build/initializing)
  and `repo`, ~400 GB free disk, 16 GB+ RAM.
- A Moto G7 Play with an **unlocked bootloader**.

### Extra host packages (on top of the stock AOSP prerequisites)

The stock AOSP prerequisite list is **not sufficient** for this tree — it builds an inline 4.9
kernel and builds Mesa3D from source. Install these as well:

```bash
sudo apt-get install -y libssl-dev libelf-dev dwarves ninja-build pkg-config python3-mako python3-yaml
pip3 install --user meson        # meson >= 1.0 (use --break-system-packages on PEP-668 distros)
export PATH="$HOME/.local/bin:$PATH"
```

| Package | Needed by | If it's missing |
|---|---|---|
| `libssl-dev` | the inline 4.9 kernel's `scripts/extract-cert` (`#include <openssl/bio.h>`) | Kernel build **fails loudly**: `fatal error: 'openssl/bio.h' file not found`. |
| `meson`, `ninja-build`, `pkg-config` | the Mesa3D/aospext build (`BOARD_BUILD_AOSPEXT_MESA3D := true`, consumed by `external/aospext`) | ⚠️ **Fails silently.** The build still reports **success**, but Mesa is skipped and no `libEGL_mesa.so` / `libGLESv2_mesa.so` / `libGLESv1_CM_mesa.so` is produced. Since `ro.hardware.egl=mesa`, the ROM then flashes fine and **bootloops**: `surfaceflinger` aborts with `couldn't find an OpenGL ES implementation, make sure one of persist.graphics.egl, ro.hardware.egl and ro.board.platform is set`, which takes zygote down with it. |
| `python3-mako` | Mesa's meson code generation | Mesa configure **fails**: `ERROR: Python (3.x) mako module >= 0.8.0 required to build mesa`. |
| `libelf-dev` | kernel host tooling | Kernel build errors. |
| `dwarves` (provides `pahole`) | generating the kernel's BTF type info (`CONFIG_DEBUG_INFO_BTF`), which the CO-RE eBPF programs (`timeInState`, `dmabufIter`) need | Kernel build **fails loudly**: `BTF: vmlinux: pahole is not available, but CONFIG_DEBUG_INFO_BTF is enabled`. Ubuntu 22.04 and 24.04 both ship pahole v1.25, the version this tree's BTF is validated against. |

To confirm Mesa actually built, check that the EGL drivers exist before flashing:

```bash
ls out/target/product/channel/vendor/lib64/egl/
# must contain: libEGL_mesa.so  libGLESv2_mesa.so  libGLESv1_CM_mesa.so
```

**Gotcha — non-interactive build shells.** `meson` (from `pip --user`) lives in `~/.local/bin`, and
ccache needs `CCACHE_EXEC`. Both are typically set in `.bashrc`, which a non-interactive build
script **does not source**. Export them in whatever drives your build:

```bash
export PATH="$HOME/.local/bin:$PATH"   # so the Mesa/aospext build can find meson
export USE_CCACHE=1
export CCACHE_EXEC=/usr/bin/ccache     # USE_CCACHE=1 alone is silently inert without this
```

## 1. Init + sync

```bash
mkdir channel-a17 && cd channel-a17

# this manifest repo (channel_a17.xml + the AOSP patches)
git clone https://github.com/keyur2maru/android_channel_manifest

# AOSP 17 base. For an EXACT reproduction of the reference build, pin the manifest to
#   commit 29ace668ae756c7b8917c57abb440f6518844b0c  (android17-release @ 2026-06-16)
repo init -u https://android.googlesource.com/platform/manifest -b android17-release

# add the channel manifest (forks + LineageOS grafts, all pinned to exact SHAs)
mkdir -p .repo/local_manifests
cp android_channel_manifest/channel_a17.xml .repo/local_manifests/

repo sync -j"$(nproc)"
```

This pulls the AOSP base, the LineageOS lineage-23.0 grafts (device/kernel/hardware
scaffolding), and the `channel` forks (github.com/keyur2maru).

## 2. Apply the patches

The device / kernel / hardware / graphics changes are git forks pinned by the manifest.
Everything else that needs changing rides as a patch, applied post-sync by
`apply-aosp-patches.sh`:

- **AOSP base tweaks** — xz ramdisk, `perl` in the build sandbox, a recovery HAL bump,
  the Mesa KGSL graphics port, … (`build/make`, `build/soong`, `external/e2fsprogs`,
  `external/mesa3d`, `external/mksh`, `frameworks/hardware/interfaces`,
  `frameworks/native`, `system/tools/hidl`).
- **Legacy-vendor adaptations** — the vendor image is frozen at Android 11 and the kernel is
  4.9, so a few AOSP-base projects need adapting: `system/memory/libion` (AOSP stubbed libion
  out for dmabuf-heaps devices; the A11 blobs allocate through it, so the real implementation
  is restored), `hardware/interfaces` (restore an FCM 5 framework matrix — the device manifest
  is `target-level="5"`), `system/bpf` + `packages/modules/Connectivity` (honour
  `ro.bpf.kver_override`, so the 4.9 kernel carrying the 5.4-era eBPF backport can declare what
  it really supports), `system/memory/libmeminfo` (don't abort system_server on the absent
  gpuMem BPF map), `external/skia` (sample-only AHardwareBuffers as external GL textures — the
  a5xx upload path corrupts them otherwise), `packages/apps/Camera2` (edge-to-edge nav-bar
  inset), `packages/modules/Bluetooth` (exit cleanly instead of aborting when the vendor BT
  controller can't start), `system/core` (libsysutils recovery variant).
  ⚠️ `patches/system/core/0002-*` **forces SELinux permissive** — a bring-up crutch while the
  policy is triaged. Drop that patch to build enforcing.
- **LineageOS graft tweaks** — the grafts are pinned to *unmodified* upstream LineageOS,
  so the handful of changes needed to build them against AOSP-17 (rather than a full
  LineageOS tree) are patches too: `hardware/lineage/compat` (AOSP-17 libgui/gralloc/audio
  ABI), `hardware/lineage/interfaces` (drop the Pixel-dependent power HAL),
  `hardware/motorola` (overlay + lineage-HAL sepolicy without the LOS framework),
  `hardware/qcom-caf/wlan` (build `wcnss_service`; keep the wlan modules in the default
  namespace), `vendor/qcom/opensource/dataservices` (legacy rmnet ioctl API),
  `vendor/codeaurora/telephony` (IMS compat entry points).
- **A generated namespace stub** — `hardware/qcom-caf/msm8953/Android.bp`. That path is
  owned by no git project (only its `audio/`, `media/`, `display/` children are projects),
  so `repo sync` never creates it and it can't be a patch; the script writes it.
The inline 4.9 kernel builds with the clang **AOSP already ships** (`r584948`, soong's
`ClangDefaultVersion`) — **no toolchain is fetched out of band.** This tree used to pin
clang-r536225 (clang 19, downloaded separately) on the belief that newer clang miscompiles
this msm-4.9.337 tree. That was wrong: newer clang does not miscompile the kernel, it
declines to compile it. `-Wdefault-const-init-*` and `-Wimplicit-enum-enum-cast` (neither
existed in clang 19) reject five genuine bugs in the QCOM `techpack/audio` vendor code —
`const` objects that are written after declaration, and result codes returned from the wrong
enum. Those are fixed in the kernel fork, and the resulting kernel boots with BTF, the eBPF
programs and Mesa all intact.

(The former gralloc2-mapper and flashlight source patches were migrated off AOSP
source to device release-config aconfig flag values — see the `vendor/lineage`
fork; that fork is required for those two behaviors.)

**Graphics (`patches/external/mesa3d/`, 4 patches).** These add a **KGSL winsys backend**
to Freedreno so Mesa can drive the Adreno 506 through the downstream KGSL kernel driver
(this SoC has no DRM/`msm` KMS driver). Two things to know:

- ⚠️ **The patches are inert on their own.** Nothing in `external/mesa3d` turns the backend
  on — the switch is `BOARD_MESA3D_EXTRA_MESON_ARGS := -Dfreedreno-kmds=kgsl` in the
  `device/motorola/sdm632-common` fork. You need **both halves**.
- ⚖️ **Attribution.** The KGSL backend is **derived community work**, not original to this
  port: the per-file MIT headers and `src/freedreno/drm/kgsl/README.aosp.md` credit the
  freedreno community KGSL winsys (Mesa MR !21570 / termux `xMeM`), with portions from
  turnip's `tu_kgsl.c` (© Rob Clark / Google). **Please keep those headers and the README
  intact** in any redistribution or upstreaming.

```bash
bash android_channel_manifest/apply-aosp-patches.sh   # run from the AOSP tree root
```

Idempotent — safe to re-run; it skips patches already applied.

## 3. Proprietary blobs

The Motorola/Qualcomm A11 vendor blobs (~400 MB) can't be redistributed. Extract them with
the stock LineageOS `extract-utils` — `extract-files.py`/`proprietary-files.txt` already ship
in the device trees and `tools/extract-utils` is pinned in the manifest — from a device
running the stock ROM (or a LineageOS build):

```bash
# device connected via adb (stock ROM / LineageOS):
( cd device/motorola/sdm632-common && ./extract-files.py adb )
( cd device/motorola/channel       && ./extract-files.py adb )
# or from a stock ROM / OTA zip:   ./extract-files.py <path-to-rom.zip>
```

This populates `vendor/motorola/{channel,sdm632-common}`. No custom scripting — pure stock
LineageOS flow.

## 4. Build

```bash
source build/envsetup.sh
lunch aosp_channel-cp2a-userdebug
m droid            # emits directly-flashable boot.img (xz ramdisk, recovery-as-boot),
                   # system.img, vendor.img (erofs), dtbo.img — no repack needed
```

## 5. Flash

```bash
adb reboot bootloader
fastboot flash boot_b   out/target/product/channel/boot.img
fastboot flash system_b out/target/product/channel/system.img
fastboot flash vendor_b out/target/product/channel/vendor.img
fastboot set_active b
fastboot reboot
```

## Layout / provenance
- **Forks** (github.com/keyur2maru, branch `channel-17.0`; kernel branch `ebpf-channel`):
  `android_device_motorola_channel`, `android_device_motorola_sdm632-common`,
  `android_device_qcom_sepolicy`, `android_hardware_qcom_display`,
  `android_vendor_qcom_opensource_display-commonsys-intf`, `android_bootable_recovery`,
  `android_kernel_motorola_sdm632`, **`android_vendor_lineage`**.

  `vendor/lineage` is a **fork, not a graft** — it carries the AOSP-17 adaptation of
  LineageOS's `lineage_generator` soong plugin (the module type behind
  `generated_kernel_includes`/`generated_kernel_headers`). Without it `soong_build` cannot
  bootstrap the plugin and **the tree will not build at all**.
- **Grafts**: LineageOS lineage-23.0, pinned in the manifest to **unmodified** upstream SHAs.
  Six of them need small changes to build against AOSP-17 instead of a full LineageOS tree;
  those ship as patches (see step 2), not forks, so the graft SHAs stay honest.
- **Patches**: `patches/<project-path>/` (applied by `apply-aosp-patches.sh`) — 17 AOSP-base
  projects + 6 LineageOS grafts, plus one generated namespace stub. See step 2. No toolchain
  is fetched: the kernel builds with the clang AOSP already ships.

All revisions are pinned to exact SHAs in `channel_a17.xml` for reproducibility.
