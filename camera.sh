#!/usr/bin/env bash
# fogos-camera-setup.sh - swap the Moto camera vendor tree to the Sedona one,
# carry over the ANC face-detection libs, and apply the Auto HDR shutter patch.
#
# Works on any fogos tree - pass the root as an argument, or run it from inside
# the tree. Nothing here is tied to a particular directory name.
#
#   bash fogos-camera-setup.sh                 # current directory
#   bash fogos-camera-setup.sh /path/to/tree
#
# What it does, idempotently:
#   1. removes vendor/motorola/motocamera if present
#   2. clones Motorola-Sedona61/vendor_motorola_camera -> vendor/motorola/camera
#   3. copies libAncFaceDetect.so / libancbase_fd.so from the old motocam repo
#   4. declares both as cc_prebuilt_library_shared in camera/Android.bp
#   5. adds them to PRODUCT_PACKAGES in camera/camera.mk
#   5b. trims any camera property over PROP_VALUE_MAX (91 chars)
#   6. repoints device tree inherits from motocamera.mk to camera.mk
#   7. fixes setup.sh / local manifest references to the old repo
#   8. runs patch_camera_hdr.sh (frameworks/av shutter-order workaround)
#   9. verifies every step and exits non-zero if anything is missing
#
# It never runs a build. No `m`, no `mka`.
set -uo pipefail

TREE="${1:-$(pwd)}"
CAM_REPO="https://github.com/Motorola-Sedona61/vendor_motorola_camera.git"
CAM_BRANCH="main"
ANC_REPO="https://github.com/adi9584/vendor_motorola_motocam.git"
ANC_BRANCH="fogos"
CAM_DIR="$TREE/vendor/motorola/camera"
OLD_DIR="$TREE/vendor/motorola/motocamera"
FAILS=0

ok(){   printf '  \033[32mPASS\033[0m  %s\n' "$*"; }
bad(){  printf '  \033[31mFAIL\033[0m  %s\n' "$*"; FAILS=$((FAILS+1)); }
warn(){ printf '  \033[33mWARN\033[0m  %s\n' "$*"; }
chg(){  printf '  \033[33mDONE\033[0m  %s\n' "$*"; }
say(){  printf '\n\033[1m== %s ==\033[0m\n' "$*"; }

# ------------------------------------------------------------------ sanity
say "0. tree check"
[ -d "$TREE" ] || { echo "ERROR: no such directory: $TREE"; exit 1; }
[ -d "$TREE/device/motorola" ] || { echo "ERROR: $TREE/device/motorola missing - not a fogos tree?"; exit 1; }
cd "$TREE" || exit 1
ok "tree: $TREE"

# ------------------------------------------------------- 1. drop old repo
say "1. remove the old motocamera tree"
if [ -d "$OLD_DIR" ]; then
  rm -rf "$OLD_DIR" && chg "removed vendor/motorola/motocamera" || bad "could not remove $OLD_DIR"
else
  ok "already absent"
fi

# ------------------------------------------------------ 2. clone new repo
say "2. install the Sedona camera tree"
if [ -f "$CAM_DIR/camera.mk" ]; then
  ok "already present ($(stat -c %s "$CAM_DIR/camera.mk") bytes)"
else
  mkdir -p "$TREE/vendor/motorola"
  git clone -q -b "$CAM_BRANCH" "$CAM_REPO" "$CAM_DIR" </dev/null \
    && chg "cloned vendor_motorola_camera@$CAM_BRANCH" \
    || bad "clone failed"
fi
[ -f "$CAM_DIR/camera.mk" ] && ok "camera.mk present" || bad "camera.mk missing"

# --------------------------------------------------------- 3. ANC libraries
say "3. carry over ANC face-detection libs"
LIBDIR="$CAM_DIR/proprietary/vendor/lib64"
mkdir -p "$LIBDIR"
need=0
for f in libAncFaceDetect.so libancbase_fd.so; do
  [ -f "$LIBDIR/$f" ] || need=1
done
if [ "$need" = "0" ]; then
  ok "both libs already present"
else
  TMP=$(mktemp -d -p "$TREE" .camsetup.XXXXXX)   # /tmp is often a small tmpfs; use the tree
  if git clone -q --depth=1 -b "$ANC_BRANCH" "$ANC_REPO" "$TMP/motocam" </dev/null; then
    for f in libAncFaceDetect.so libancbase_fd.so; do
      src="$TMP/motocam/proprietary/vendor/lib64/$f"
      if [ -f "$src" ]; then
        sz=$(stat -c %s "$src")
        if [ "$sz" -lt 1024 ]; then
          warn "$f looks like a Git LFS pointer ($sz bytes) - trying git lfs pull"
          ( cd "$TMP/motocam" && git lfs pull >/dev/null 2>&1 )
          sz=$(stat -c %s "$src" 2>/dev/null || echo 0)
        fi
        if [ "$sz" -ge 1024 ]; then
          cp "$src" "$LIBDIR/$f" && chg "copied $f ($sz bytes)"
        else
          bad "$f is not a real blob - install git-lfs and re-run"
        fi
      else
        bad "$f not found in the motocam repo"
      fi
    done
  else
    bad "could not clone $ANC_REPO"
  fi
  rm -rf "$TMP"
fi

# ------------------------------------------------------- 4. Android.bp mods
say "4. declare the libs in camera/Android.bp"
BP="$CAM_DIR/Android.bp"
if [ -f "$BP" ]; then
  python3 - "$BP" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
block = '''cc_prebuilt_library_shared {
    name: "libAncFaceDetect",
    owner: "motorola",
    strip: { none: true },
    target: {
        android_arm64: {
            srcs: ["proprietary/vendor/lib64/libAncFaceDetect.so"],
            shared_libs: ["libancbase_fd", "libc", "libm", "libdl", "liblog"],
        },
    },
    compile_multilib: "64",
    vendor: true,
}

cc_prebuilt_library_shared {
    name: "libancbase_fd",
    owner: "motorola",
    strip: { none: true },
    target: {
        android_arm64: {
            srcs: ["proprietary/vendor/lib64/libancbase_fd.so"],
            shared_libs: ["libm", "liblog", "libdl", "libc"],
        },
    },
    compile_multilib: "64",
    vendor: true,
}
'''
if 'name: "libAncFaceDetect"' in s and 'name: "libancbase_fd"' in s:
    print('  already declared')
else:
    # drop a previously mangled/partial block, then append a clean one
    marker = 'cc_prebuilt_library_shared {\n    name: "libAncFaceDetect"'
    i = s.find(marker)
    if i >= 0:
        s = s[:i].rstrip() + '\n'
    if not s.endswith('\n'):
        s += '\n'
    open(p, 'w').write(s + '\n' + block)
    print('  block written')
PY
  python3 -c "
s=open('$BP').read()
print('  braces balanced:', s.count('{')==s.count('}'))"
  grep -q 'name: "libAncFaceDetect"' "$BP" && ok "libAncFaceDetect module" || bad "libAncFaceDetect module missing"
  grep -q 'name: "libancbase_fd"'    "$BP" && ok "libancbase_fd module"    || bad "libancbase_fd module missing"
else
  bad "no Android.bp in $CAM_DIR"
fi

# ------------------------------------------------------- 5. camera.mk mods
say "5. add the libs to PRODUCT_PACKAGES"
MK="$CAM_DIR/camera.mk"
if [ -f "$MK" ]; then
  if grep -q 'libAncFaceDetect' "$MK"; then
    ok "already listed"
  else
    printf '\n# Motorola face detection (carried over from the motocam tree)\nPRODUCT_PACKAGES += libAncFaceDetect libancbase_fd\n' >> "$MK"
    chg "appended PRODUCT_PACKAGES line"
  fi
  grep -q 'libAncFaceDetect' "$MK" && ok "camera.mk lists libAncFaceDetect" || bad "camera.mk missing the package"
else
  bad "no camera.mk"
fi

# --------------------------------------------- 5b. property value length
say "5b. property length (PROP_VALUE_MAX = 91 chars)"
if [ -f "$MK" ]; then
  python3 - "$MK" <<'PYP'
import re, sys
p = sys.argv[1]
lines = open(p).read().splitlines(True)
out, notes = [], []
for l in lines:
    if l.lstrip().startswith('#'):
        out.append(l); continue
    m = re.match(r'^(\s*)([A-Za-z0-9_.]+)(\??=)(\s*)(.*?)(\s*\\?\s*)$', l.rstrip('\n'))
    if m:
        indent, name, op, sp, val, tail = m.groups()
        val = val.strip().strip('"')
        if len(val) > 91:
            if name == 'vendor.camera.aux.packagelist':
                trimmed = ','.join(x for x in val.split(',') if x != 'com.motorola.camera5')
                if len(trimmed) <= 91:
                    l = f'{indent}{name}{op}{sp}{trimmed}{tail}\n'
                    notes.append(f'{name}: {len(val)} -> {len(trimmed)} bytes (dropped com.motorola.camera5)')
                else:
                    notes.append(f'{name}: {len(val)} bytes, still over after trim - shorten by hand')
            else:
                notes.append(f'{name}: {len(val)} bytes - too long, shorten by hand')
    out.append(l)
open(p, 'w').write(''.join(out))
print('\n'.join('  ' + n for n in notes) if notes else '  all property values within 91 bytes')
PYP
  OVER=$(python3 - "$MK" <<'PYQ'
import re, sys
bad = []
for l in open(sys.argv[1]):
    if l.lstrip().startswith('#'):
        continue
    m = re.match(r'^\s*([A-Za-z0-9_.]+)\??=\s*(.*?)\s*\\?\s*$', l)
    if m and len(m.group(2).strip().strip('"')) > 91:
        bad.append(m.group(1))
print(' '.join(bad))
PYQ
)
  if [ -z "$OVER" ]; then
    ok "no property exceeds 91 bytes"
  else
    bad "still over the limit: $OVER"
  fi
fi

# ------------------------------------------------------- 6. device tree refs
say "6. repoint device tree inherits"
python3 - "$TREE" <<'PY'
import pathlib, sys
tree = pathlib.Path(sys.argv[1])
changed = []
for p in (tree / 'device' / 'motorola').rglob('*.mk'):
    s = p.read_text(errors='replace')
    o = s
    s = s.replace('vendor/motorola/motocamera/motocamera.mk',
                  'vendor/motorola/camera/camera.mk')
    # sepolicy from the old tree no longer exists in the new one
    s = '\n'.join(l for l in s.splitlines()
                  if 'motocamera/sepolicy' not in l)
    if s != o:
        p.write_text(s)
        changed.append(str(p.relative_to(tree)))
print('  updated:', changed or 'nothing to change')
PY
grep -rq 'vendor/motorola/camera/camera.mk' device/motorola 2>/dev/null \
  && ok "a device tree inherits camera.mk" || bad "no device tree inherits camera.mk"
if grep -rq 'motocamera/motocamera.mk' device/motorola 2>/dev/null; then
  bad "a device tree still inherits motocamera.mk"
else
  ok "no motocamera.mk inherits left"
fi

# ------------------------------------------------ 7. setup.sh + manifest
say "7. stale references (setup.sh, local manifest)"
python3 - "$TREE" "$CAM_REPO" "$CAM_BRANCH" <<'PY'
import pathlib, sys, re
tree, cam_repo, cam_branch = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]

for sh in (tree / 'device' / 'motorola').rglob('setup.sh'):
    s = sh.read_text(errors='replace')
    if 'motocamera' not in s:
        continue
    out = []
    for line in s.splitlines():
        if 'motocamera' in line and 'clone' in line:
            indent = line[:len(line) - len(line.lstrip())]
            out.append(f'{indent}clone_if_missing "{cam_repo}" "{cam_branch}" "vendor/motorola/camera"')
        else:
            out.append(line)
    sh.write_text('\n'.join(out) + '\n')
    print(f'  setup.sh updated: {sh.relative_to(tree)}')

lm = tree / '.repo' / 'local_manifests'
if lm.is_dir():
    for x in lm.glob('*.xml'):
        s = x.read_text(errors='replace')
        if 'vendor/motorola/motocamera' not in s:
            continue
        if 'name="sedona61"' not in s:
            s = s.replace('<manifest>',
                          '<manifest>\n  <remote name="sedona61" '
                          'fetch="https://github.com/Motorola-Sedona61" />', 1)
        lines = []
        for line in s.splitlines():
            if 'vendor/motorola/motocamera' in line:
                lines.append('  <remove-project path="vendor/motorola/motocamera" optional="true" />')
                lines.append('  <project path="vendor/motorola/camera" '
                             'name="vendor_motorola_camera" remote="sedona61" '
                             f'revision="{cam_branch}" />')
            else:
                lines.append(line)
        x.write_text('\n'.join(lines) + '\n')
        print(f'  manifest updated: {x.relative_to(tree)}')
PY
grep -rq 'vendor/motorola/motocamera' device/motorola/*/setup.sh 2>/dev/null \
  && bad "setup.sh still clones the old repo" || ok "setup.sh clean"

# ------------------------------------------------------------- 8. HDR patch
say "8. Auto HDR shutter patch"
if [ -f "$CAM_DIR/patch_camera_hdr.sh" ]; then
  OUT=$(bash "$CAM_DIR/patch_camera_hdr.sh" 2>&1)
  echo "$OUT" | grep -E '^\[' | sed 's/^/  /'
  if echo "$OUT" | grep -q 'A1 patched\|already patched'; then
    ok "cameraserver shutter workaround applied"
  else
    bad "A1 patch did not apply - check frameworks/av"
  fi
  if echo "$OUT" | grep -q 'A3 blob present'; then
    ok "A3 face-detection blob found"
  else
    warn "A3 blob not detected (see output above)"
  fi
  if echo "$OUT" | grep -q '\[FAIL\] A2'; then
    warn "A2: MotCamera4.apk is a Git LFS pointer - run 'git lfs pull' in $CAM_DIR"
    warn "    (the camera will not ship correctly until that is a real APK)"
  fi
else
  bad "patch_camera_hdr.sh missing"
fi
if grep -rq 'HDR_SHUTTER_WORKAROUND' "$TREE/frameworks/av/services/camera/libcameraservice" 2>/dev/null; then
  ok "workaround marker present in frameworks/av"
else
  bad "workaround marker not found in frameworks/av"
fi

# ---------------------------------------------------------------- 9. verify
say "9. final verification"
[ -d "$OLD_DIR" ] && bad "vendor/motorola/motocamera still exists" || ok "old tree gone"
[ -f "$CAM_DIR/camera.mk" ] && ok "camera.mk" || bad "camera.mk"
for f in libAncFaceDetect.so libancbase_fd.so; do
  if [ -f "$LIBDIR/$f" ]; then
    sz=$(stat -c %s "$LIBDIR/$f")
    if [ "$sz" -ge 1024 ]; then ok "$f ($sz bytes)"; else bad "$f is a stub ($sz bytes)"; fi
  else
    bad "$f missing"
  fi
done
python3 -c "
s=open('$BP').read()
import sys
sys.exit(0 if s.count('{')==s.count('}') else 1)" \
  && ok "Android.bp braces balanced" || bad "Android.bp braces unbalanced"

printf '\n'
if [ "$FAILS" -eq 0 ]; then
  echo "  all checks passed - camera tree is set up"
  echo "  next: run your build (not run by this script)"
  exit 0
else
  echo "  $FAILS check(s) failed"
  exit 1
fi
