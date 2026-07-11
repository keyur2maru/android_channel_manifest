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

applied=0 skipped=0
while IFS= read -r d; do
  proj="${d#"$PATCHES"/}"
  repo="$TOP/$proj"
  [ -d "$repo/.git" ] || { echo "SKIP  $proj  (not synced)"; skipped=$((skipped+1)); continue; }

  # gather this project's patches in order
  mapfile -t pfiles < <(ls "$d"/*.patch 2>/dev/null | sort)
  [ "${#pfiles[@]}" -eq 0 ] && continue

  # already applied? (match the first patch's subject in recent history)
  subj=$(sed -n 's/^Subject: \[PATCH[^]]*\] //p' "${pfiles[0]}" | head -1)
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
