#!/usr/bin/env bash
# AxionOS / fogos - every change we made, merged into one idempotent pass.
#
#   1. Signing keys present (restore from backup, or refuse)
#   2. LineageOS "Twelve" removed
#   3. PixelPlayer added
#   4. FogosParts cloned + wired
#   5. Picture Control disabled
#   6. AxDragoniteBoost disabled
#   7. GlassBlur cherry-picked into frameworks/native
#   8. AxDiagnostics: 156C bogus-zone filter + 90C thermal threshold
#   9. Verify
#
# NOT included: the dynamic bar collapse fix. It was applied and then reverted,
# so the tree is intentionally back to stock 2.9 behaviour there.
#
# Run from the ROM tree root:  bash axion-fogos-merged.sh
# Optional:  BUILD=1 bash axion-fogos-merged.sh   (also runs `m bacon`)
set -euo pipefail

DEV="${DEV:-device/motorola/fogos}"
AXD=packages/apps/AxDiagnostics/src/com/axion/diagnostics/data
SDKFILE=axion_sdk/ax_dragonite/ax_dragonite_server/src/com/android/server/axdragonite/AxDragoniteImpl.kt
FWN=frameworks/native
PP=vendor/pixelplayer/PixelPlayer
APK=PixelPlayer-arm64-v8a.apk
APK_URL="https://github.com/PixelPlayerHQ/PixelPlayer/releases/download/0.7.5-beta/${APK}"
BUILD="${BUILD:-0}"

[ -d .repo ]            || { echo "ERROR: no .repo here. Run from the ROM tree root."; exit 1; }
[ -d "$DEV" ]           || { echo "ERROR: $DEV missing - device tree not synced."; exit 1; }
[ -f "$DEV/device.mk" ] || { echo "ERROR: $DEV/device.mk missing."; exit 1; }

# ---- 1. signing keys -------------------------------------------------
echo "=== 1. signing keys ==="
if [ -d vendor/lineage-priv/keys ]; then
  echo "  present"
elif [ -f "$HOME/axion-keys.tar.gz" ]; then
  echo "  restoring from ~/axion-keys.tar.gz"
  mkdir -p vendor/lineage-priv
  tar xzf "$HOME/axion-keys.tar.gz" -C . 2>/dev/null || tar xzf "$HOME/axion-keys.tar.gz"
elif [ "${ALLOW_NEW_KEYS:-0}" = "1" ]; then
  echo "  missing - ALLOW_NEW_KEYS=1, build will use new keys (needs a wipe to flash over)"
else
  echo "ERROR: vendor/lineage-priv/keys missing and no ~/axion-keys.tar.gz."
  echo "       Re-run with ALLOW_NEW_KEYS=1 if a new signing identity is acceptable."
  exit 1
fi

# ---- 2. Twelve -------------------------------------------------------
echo "=== 2. LineageOS Twelve ==="
mapfile -t MK < <(grep -rlE '^[[:space:]]*Twelve[[:space:]]*\\{0,1}[[:space:]]*$' \
                    vendor/*/config/*.mk 2>/dev/null || true)
if [ "${#MK[@]}" -eq 0 ]; then
  echo "  not present"
else
  for p in "${MK[@]}"; do
    python3 - "$p" <<'PY'
import re, sys
p = sys.argv[1]; s = open(p).read()
lines = [l for l in s.splitlines(keepends=True) if not re.match(r'^\s*Twelve\s*\\?\s*$', l)]
n = ''.join(lines)
n = re.sub(r'[ \t]*\\[ \t]*\r?\n(?=[ \t]*\r?\n|[ \t]*endif\b)', '\n', n)
if n != s:
    open(p, 'w').write(n); print(f"  {p}: removed")
else:
    print(f"  {p}: unchanged")
PY
  done
fi

# ---- 3. PixelPlayer --------------------------------------------------
echo "=== 3. PixelPlayer ==="
mkdir -p "$PP"
if [ -f "$PP/$APK" ]; then
  echo "  apk present"
else
  echo "  downloading $(basename "$APK_URL")"
  curl -fsSL -o "$PP/$APK" "$APK_URL"
fi
cat > "$PP/Android.bp" <<'BP'
android_app_import {
    name: "PixelPlayer",
    apk: "PixelPlayer-arm64-v8a.apk",
    presigned: true,
    preprocessed: true,
    dex_preopt: {
        enabled: false,
    },
    product_specific: true,
}
BP
grep -qxF 'PRODUCT_PACKAGES += PixelPlayer' "$DEV/device.mk" || \
  echo 'PRODUCT_PACKAGES += PixelPlayer' >> "$DEV/device.mk"
echo "  wired"

# ---- 4. FogosParts ---------------------------------------------------
echo "=== 4. FogosParts ==="
if [ -d packages/apps/FogosParts ]; then
  echo "  already present"
else
  git clone --depth=1 -q -b main \
    https://github.com/tiraq-official/android_packages_apps_FogosParts.git \
    packages/apps/FogosParts </dev/null
  echo "  cloned"
fi
grep -q 'FogosParts/parts.mk' "$DEV/device.mk" || \
  echo 'include packages/apps/FogosParts/parts.mk' >> "$DEV/device.mk"
echo "  wired"

# ---- 5. Picture Control ---------------------------------------------
echo "=== 5. Picture Control ==="
M=packages/apps/FogosParts/AndroidManifest.xml
if [ -f "$M" ]; then
  N=$(grep -c 'android:enabled="false"' "$M" || true)
  if [ "$N" = "0" ]; then
    sed -i 's#android:name=".display.PictureControlActivity"#android:name=".display.PictureControlActivity"\n            android:enabled="false"#' "$M"
    echo "  disabled"
  elif [ "$N" = "1" ]; then
    echo "  already disabled"
  else
    sed -i '0,/android:enabled="false"/!{/android:enabled="false"/d}' "$M"
    echo "  duplicates removed"
  fi
else
  echo "  manifest not found - skipped"
fi

# ---- 6. AxDragoniteBoost --------------------------------------------
echo "=== 6. AxDragoniteBoost ==="
if [ -f "$SDKFILE" ]; then
  git -C axion_sdk rev-parse --git-dir >/dev/null 2>&1 && \
    git -C axion_sdk checkout -- \
      ax_dragonite/ax_dragonite_server/src/com/android/server/axdragonite/AxDragoniteImpl.kt || true
  python3 - "$SDKFILE" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
if "BOOST_DISABLED_FOR_DEVICE" in s:
    print("  already disabled"); raise SystemExit
a = "    fun dispatchSceneCommands(sceneId: Int, bundle: Bundle?) {\n"
if a not in s:
    print("  ANCHOR NOT FOUND - patch by hand"); raise SystemExit(1)
ins = ("    // Boost disabled on this device: a working boost pins the CPU and\n"
       "    // confines SF/RenderEngine to 4 of 8 cores here, which measures worse\n"
       "    // than leaving it off. Handles are still allocated and released.\n"
       "    private val BOOST_DISABLED_FOR_DEVICE = true\n\n"
       + a + "        if (BOOST_DISABLED_FOR_DEVICE) return\n")
open(p, "w").write(s.replace(a, ins, 1)); print("  disabled")
PY
else
  echo "  $SDKFILE not found - is axion_sdk synced?"
fi

# ---- 7. GlassBlur ----------------------------------------------------
echo "=== 7. GlassBlur ==="
if [ -f "$FWN/libs/renderengine/skia/filters/GlassBlurFilter.cpp" ] && \
   grep -q "GlassBlurFilter.cpp" "$FWN/libs/renderengine/Android.bp" 2>/dev/null && \
   grep -q "new GlassBlurFilter" "$FWN/libs/renderengine/skia/SkiaRenderEngine.cpp" 2>/dev/null; then
  echo "  already present"
elif [ ! -d "$FWN/.git" ]; then
  echo "  $FWN missing or not a git repo - skipped"
else
  if [ -n "$(git -C "$FWN" status --porcelain 2>/dev/null)" ]; then
    echo "  ERROR: $FWN has uncommitted changes:"; git -C "$FWN" status --short | head -8 | sed 's/^/    /'
    exit 1
  fi
  git -C "$FWN" fetch --depth=400 https://github.com/AxionAOSP/android_frameworks_native.git ax-dragonite-dev 2>&1 | tail -1
  for c in 06ae3c3645 ea0184011c; do
    git -C "$FWN" cat-file -e "${c}^{commit}" 2>/dev/null || { echo "  ERROR: $c not fetched"; exit 1; }
  done
  git -C "$FWN" -c user.email=local@local -c user.name=local cherry-pick 06ae3c3645 ea0184011c
fi

# ---- 8. AxDiagnostics ------------------------------------------------
echo "=== 8. AxDiagnostics ==="
TI=$AXD/ThermalInfo.kt
HA=$AXD/HealthAnalyzer.kt
if [ -f "$TI" ]; then
  python3 - "$TI" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
if "tempC < 0f || tempC > 125f" in s:
    print("  ThermalInfo: already filtered"); raise SystemExit
a = "                val tempC = if (kotlin.math.abs(temp) > 200L) temp / 1000f else temp.toFloat()\n"
if a not in s:
    print("  ThermalInfo: ANCHOR NOT FOUND"); raise SystemExit(1)
add = a + (
"                // Some zones report a raw ADC value rather than a temperature: 156000 passes\n"
"                // the >200 millidegree heuristic above and becomes 156 C, which then wins\n"
"                // maxByOrNull and raises a bogus \"Thermal emergency\". Anything outside this\n"
"                // range is not a junction temperature, so drop the zone instead of reporting it.\n"
"                if (tempC < 0f || tempC > 125f) return@forEach\n")
open(p, "w").write(s.replace(a, add, 1)); print("  ThermalInfo: 156C filter added")
PY
else
  echo "  ThermalInfo.kt not found"
fi
if [ -f "$HA" ]; then
  python3 - "$HA" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
if "maxTemperature > 90f" in s:
    print("  HealthAnalyzer: already 90C"); raise SystemExit
a = "            thermal.maxTemperature > 60f -> insights.add("
if a not in s:
    print("  HealthAnalyzer: ANCHOR NOT FOUND"); raise SystemExit(1)
open(p, "w").write(s.replace(a, "            thermal.maxTemperature > 90f -> insights.add(", 1))
print("  HealthAnalyzer: 60 -> 90C")
PY
else
  echo "  HealthAnalyzer.kt not found"
fi

# ---- 9. verify -------------------------------------------------------
echo "=== VERIFY ==="
fail=0
c() { if [ "$2" = "$3" ]; then printf '  PASS  %-32s %s\n' "$1" "$2"
      else printf '  FAIL  %-32s got %s want %s\n' "$1" "$2" "$3"; fail=$((fail+1)); fi; }
c "Twelve removed"          "$(grep -rhcE '^[[:space:]]*Twelve[[:space:]]*\\{0,1}[[:space:]]*$' vendor/*/config/*.mk 2>/dev/null | awk '{s+=$1} END{print s+0}')" 0
c "no dangling backslash"   "$(grep -rhB1 '^endif' vendor/*/config/*.mk 2>/dev/null | grep -c '\\$' || true)" 0
c "PixelPlayer apk"         "$(test -f "$PP/$APK" && echo 1 || echo 0)" 1
c "PixelPlayer in device.mk" "$(grep -c 'PRODUCT_PACKAGES += PixelPlayer' "$DEV/device.mk" || true)" 1
c "parts.mk referenced"     "$(grep -c 'FogosParts/parts.mk' "$DEV/device.mk" || true)" 1
[ -f "$M" ] && c "PicCtrl disabled" "$(grep -A1 'PictureControlActivity' "$M" | grep -c 'android:enabled="false"' || true)" 1
c "dragonite guard"         "$(grep -c 'BOOST_DISABLED_FOR_DEVICE' "$SDKFILE" 2>/dev/null || true)" 2
c "thermal 156C filter"     "$(grep -c 'tempC < 0f || tempC > 125f' "$TI" 2>/dev/null || true)" 1
c "thermal threshold 90C"   "$(grep -c 'maxTemperature > 90f' "$HA" 2>/dev/null || true)" 1
echo
if [ "$fail" != "0" ]; then echo "ABORTING: $fail check(s) failed"; exit 1; fi
echo "all checks passed"

if [ "$BUILD" = "1" ]; then
  echo "=== build ==="
  source build/envsetup.sh
  breakfast fogos            # or: lunch axion_fogos-userdebug
  m bacon
fi
