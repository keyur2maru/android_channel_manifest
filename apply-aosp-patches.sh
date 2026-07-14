#!/usr/bin/env bash
#
# Apply the channel AOSP-17 framework/build patches after `repo sync`.
#
# The device/kernel/hardware/graphics changes ship as git forks pinned in the
# manifest (channel_a17.xml). A handful of small AOSP framework/build tweaks can't
# be hosted as forks cheaply, so they ride as patches applied here. Run this ONCE
# on a freshly-synced tree, from the AOSP tree root:
#
#     bash apply-aosp-patches.sh
#
set -euo pipefail

TOP="${ANDROID_BUILD_TOP:-$(pwd)}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCHES="$HERE/patches"

[ -d "$PATCHES" ] || { echo "error: patches/ not found next to this script ($PATCHES)"; exit 1; }
[ -d "$TOP/build/soong" ] || { echo "error: run from the AOSP tree root (build/soong not found under $TOP)"; exit 1; }

# Identity for the applied commits (git am needs a committer). Override via env if you like.
export GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-channel builder}"
export GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-channel@localhost}"

##
## Step 1 — lay down generated namespace stub files.
##
## A couple of Android.bp files in this tree sit at a path that NO git project owns,
## so they cannot ride as a git-am patch (there is nothing to apply them to). Under
## hardware/qcom-caf/msm8953 only the CHILDREN (audio/, media/, display/) are repo
## projects — the msm8953 directory itself is not — yet soong needs an Android.bp
## there to declare the namespace those children live in. `repo sync` never creates
## it, so we generate it here.
##
## NOTE: the two other unowned Android.bp files in the tree,
##   vendor/motorola/sdm632-common/Android.bp  and  vendor/motorola/channel/Android.bp
## do NOT need recreating — they are emitted by the blob extraction
## (extract-files.py / setup-makefiles.py; see README step 3) and ship with the
## extracted vendor blobs.
##
## Idempotent: only writes when the file is missing or its content differs.
write_stub() { # $1 = tree-relative path, $2 = content
  local path="$TOP/$1" content="$2"
  if [ -f "$path" ] && [ "$(cat "$path")" = "$content" ]; then
    echo "OK    $1  (namespace stub already present)"
    return
  fi
  mkdir -p "$(dirname "$path")"
  printf '%s\n' "$content" > "$path"
  echo "WRITE $1  (namespace stub)"
}

write_stub hardware/qcom-caf/msm8953/Android.bp 'soong_namespace {
    imports: [
        "vendor/qcom/opensource/commonsys-intf/display",
    ],
}'

## external/aospext/Android.mk is a legacy Android.mk, which AOSP's androidmk denylist
## rejects outright ("every build fatals"). The supported escape hatch is an allowlist at
## vendor/google/build/androidmk/allowlist.txt — a path no git project owns, so it can't
## ride as a patch either. Without it, Mesa3D never builds: no libEGL_mesa.so, and since
## ro.hardware.egl=mesa the ROM bootloops (surfaceflinger: "couldn't find an OpenGL ES
## implementation").
write_stub vendor/google/build/androidmk/allowlist.txt 'external/aospext/Android.mk'

##
## Step 2 — apply the per-project patches.
##
applied=0 skipped=0
while IFS= read -r d; do
  proj="${d#"$PATCHES"/}"
  repo="$TOP/$proj"

  # gather this project's patches in order; intermediate dirs (patches/hardware,
  # patches/vendor/qcom, …) hold no patches of their own — skip them silently.
  mapfile -t pfiles < <(ls "$d"/*.patch 2>/dev/null | sort)
  [ "${#pfiles[@]}" -eq 0 ] && continue

  [ -d "$repo/.git" ] || { echo "SKIP  $proj  (not synced)"; skipped=$((skipped+1)); continue; }

  # Already applied? (match the first patch's subject in recent history.) Use
  # git mailinfo rather than sed: format-patch FOLDS long subjects across
  # continuation lines, and mailinfo unfolds them exactly the way git am does,
  # so this compares against the same string that lands in the commit log.
  subj=$(git mailinfo /dev/null /dev/null < "${pfiles[0]}" 2>/dev/null | sed -n 's/^Subject: //p' | head -1)
  if [ -n "$subj" ] && git -C "$repo" log -50 --format='%s' | grep -qxF "$subj"; then
    echo "SKIP  $proj  (already applied)"; skipped=$((skipped+1)); continue
  fi

  echo "APPLY $proj  (${#pfiles[@]} patch(es))"
  if ! git -C "$repo" am --3way --keep-cr "${pfiles[@]}"; then
    echo "  ERROR: git am failed in $proj — aborting that project." >&2
    git -C "$repo" am --abort 2>/dev/null || true
    exit 1
  fi
  applied=$((applied+1))
done < <(find "$PATCHES" -mindepth 1 -type d | sort)

echo "done: $applied project(s) patched, $skipped skipped."

##
## Step 3 — fetch the clang-r536225 kernel toolchain.
##
## The inline 4.9 kernel build pins TARGET_KERNEL_CLANG_VERSION := r536225 (clang 19), the
## toolchain the OEM/LineageOS used for this msm-4.9.337 tree. AOSP-17's prebuilts/clang only
## ships clang 20+ (r547379 …), and building this kernel with clang 20 MISCOMPILES it (faults
## before console init -> splash bootloop, no pstore). r536225 is still carried on other AOSP
## branches, so fetch it into the prebuilts project (untracked there — it is a 3.6 GB binary
## toolchain, not something that can ride as a patch).
##
CLANG_VER=r536225
CLANG_DIR="$TOP/prebuilts/clang/host/linux-x86/clang-$CLANG_VER"
CLANG_URL="https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/refs/heads/main/clang-$CLANG_VER.tar.gz"

if [ -x "$CLANG_DIR/bin/clang" ]; then
  echo "OK    prebuilts/clang/host/linux-x86/clang-$CLANG_VER  (kernel toolchain already present)"
else
  echo "FETCH clang-$CLANG_VER kernel toolchain (~1.1 GB download, ~3.6 GB unpacked)"
  mkdir -p "$CLANG_DIR"
  # gitiles +archive tarballs have no top-level directory — unpack straight into the dir.
  if ! curl -fL --retry 3 "$CLANG_URL" | tar xz -C "$CLANG_DIR"; then
    echo "  ERROR: could not fetch $CLANG_URL" >&2
    echo "  The kernel will NOT boot if built with AOSP-17's clang 20. Fetch clang-$CLANG_VER" >&2
    echo "  manually into $CLANG_DIR (try the android16-release branch if main has pruned it)." >&2
    rmdir "$CLANG_DIR" 2>/dev/null || true
    exit 1
  fi
  [ -x "$CLANG_DIR/bin/clang" ] || { echo "  ERROR: unpacked toolchain has no bin/clang" >&2; exit 1; }
  echo "OK    clang-$CLANG_VER unpacked ($("$CLANG_DIR/bin/clang" --version | head -1))"
fi
