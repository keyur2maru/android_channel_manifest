# AOSP 17 for the Moto G7 Play (`channel`)

Unofficial AOSP Android 17 port for the Motorola Moto G7 Play (codename **`channel`**,
Qualcomm **SDM632 / msm8953**, Adreno 506, inline Linux **4.9** kernel). Open Mesa/Freedreno
GL, SDE fbdev composer, eBPF-1:1 backport on the 4.9 kernel. Boots to home; GPU / Wi-Fi / BT /
camera / flashlight work.

## What you need
- A Linux host with the [AOSP build prerequisites](https://source.android.com/setup/build/initializing)
  and `repo`, ~400 GB free disk, 16 GB+ RAM.
- A Moto G7 Play with an **unlocked bootloader**.

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

## 2. Apply the AOSP framework/build patches

The device / kernel / hardware / graphics changes are git forks pinned by the manifest.
A few small AOSP framework/build tweaks (xz ramdisk, `perl` in the build sandbox, a
gralloc2 mapper fix, a flashlight fix, a recovery HAL bump, …) ride as patches:

```bash
bash android_channel_manifest/apply-aosp-patches.sh   # run from the AOSP tree root
```

Idempotent — safe to re-run; it skips patches already applied.

## 3. Proprietary blobs

The Motorola/Qualcomm A11 vendor blobs (654 `.so`, ~400 MB) can't be redistributed.
Provide them under `vendor/motorola/{channel,sdm632-common}` by extracting from a device
running the stock ROM or a LineageOS build. _(extract-files.sh: TODO — for now, copy the
`vendor/motorola/{channel,sdm632-common}` trees from a known-good checkout.)_

## 4. Build

```bash
source build/envsetup.sh
lunch aosp_channel-cp2a-userdebug
m droid            # boot.img, system, vendor (erofs), dtbo
```

_(Note: `m droid` → directly-flashable images is the in-progress build-parity work; the
current daily driver uses a per-image build + a boot.img repack with an xz ramdisk. See
the project notes.)_

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
- **Forks** (github.com/keyur2maru, branch `channel-17.0`; kernel `bpf-54plus-channel`):
  `android_device_motorola_channel`, `android_device_motorola_sdm632-common`,
  `android_device_qcom_sepolicy`, `android_hardware_qcom_display`,
  `android_vendor_qcom_opensource_display-commonsys-intf`, `android_bootable_recovery`,
  `android_kernel_motorola_sdm632`.
- **Grafts**: LineageOS lineage-23.0 (pinned in the manifest).
- **AOSP patches**: `patches/` (applied by `apply-aosp-patches.sh`).

All revisions are pinned to exact SHAs in `channel_a17.xml` for reproducibility.
