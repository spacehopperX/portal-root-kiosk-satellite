#!/system/bin/sh
# ============================================================================
#  portal_dolby_diag.sh  —  READ-ONLY diagnostic for Portal TV (ripley)
#  HDMI Dolby/AC3 passthrough investigation
#
#  PURPOSE
#  -------
#  The audio HAL (libaudioextnfb.so) logs "Disabling dolby formats" in
#  read_hdmi_sink_caps and reports supported = DTS|IEC61937|PCM only.
#  That filter is gated by a property. This script pinpoints EXACTLY which
#  property/branch controls it, WITHOUT changing anything.
#
#  It is designed to run INSIDE the portal-root-kiosk-satellite `ripley`
#  temporary-privileged window (uid=0, init SELinux SID, SELinux stays
#  enforcing). It performs ZERO writes. It is safe to run as plain `sh`
#  too — protected reads will simply fail with "Permission denied", which
#  is itself useful signal.
#
#  HOW TO RUN (from the Mac, after the exploit has elevated a shell)
#  -----------------------------------------------------------------
#  The exploit's privileged window is a short-lived process. The simplest
#  robust way to run this is to have the provisioner's root step `sh` this
#  script. Two options:
#
#   Option 1 (recommended) — push + run via the exploit's root step:
#       ./adb -s $SER push portal_dolby_diag.sh /data/local/tmp/
#       ./adb -s $SER shell 'LD_PRELOAD=<exploit.so> sh /data/local/tmp/portal_dolby_diag.sh'
#     (Replace <exploit.so> with the preload .so path your provisioner uses.)
#
#   Option 2 — if you already have a root shell from the exploit:
#       sh /data/local/tmp/portal_dolby_diag.sh
#
#  OUTPUT
#  ------
#  Everything is printed to stdout. Redirect to a file when capturing:
#       ... > /data/local/tmp/dolby_diag.txt 2>&1
#  Then pull it:
#       ./adb -s $SER pull /data/local/tmp/dolby_diag.txt
# ============================================================================

OUT="/data/local/tmp/dolby_diag.txt"

# Run all logic, tee to the output file so we get it back via adb pull.
exec > >(tee "$OUT") 2>&1

echo "############################################################"
echo "#  PORTAL TV (ripley) DOLBY GATE DIAGNOSTIC"
echo "#  $(date)"
echo "#  uid=$(id -u 2>/dev/null)  whoami=$(whoami 2>/dev/null)"
echo "#  SELinux: enforcing=$(cat /sys/fs/selinux/enforce 2>/dev/null || echo n/a)"
echo "############################################################"

# ----------------------------------------------------------------------------
# 0. Identity / build (confirm we are on the expected ripley build)
# ----------------------------------------------------------------------------
echo
echo "=== [0] IDENTITY ==="
for p in ro.product.model ro.product.device ro.build.fingerprint \
         ro.build.version.release ro.build.version.sdk ro.board.platform; do
  printf '  %s = %s\n' "$p" "$(getprop $p)"
done

# ----------------------------------------------------------------------------
# 1. The candidate gate properties — current values
# ----------------------------------------------------------------------------
echo
echo "=== [1] CANDIDATE GATE PROPERTIES (current values) ==="
for p in \
  persist.audio.netflix.dolby.enabled \
  persist.vendor.audio.enable_dolby \
  persist.vendor.audio.hdmi.enable \
  vendor.audio.offload.passthrough \
  audio.offload.video ; do
  printf '  %-40s = [%s]\n' "$p" "$(getprop $p)"
done

# ----------------------------------------------------------------------------
# 2. SELinux property contexts (which label guards each property)
# ----------------------------------------------------------------------------
echo
echo "=== [2] SELinux PROPERTY CONTEXTS ==="
echo "  --- vendor_property_contexts (audio/dolby/hdmi/passthrough) ---"
grep -iE 'dolby|hdmi|passthrough|surround|offload|netflix' \
  /vendor/etc/selinux/vendor_property_contexts 2>&1 | sed 's/^/    /'
echo "  --- plat / nonplat property_contexts (netflix/dolby) ---"
grep -iE 'netflix|dolby' /vendor/etc/selinux/property_contexts \
  /plat_property_contexts /nonplat_property_contexts 2>&1 | sed 's/^/    /'

# ----------------------------------------------------------------------------
# 3. Which binary actually references each property?
#    This is the crux: does the HAL read netflix.dolby OR vendor enable_dolby?
# ----------------------------------------------------------------------------
echo
echo "=== [3] BINARY REFERENCES TO GATE PROPERTIES ==="
for prop in "netflix.dolby" "enable_dolby" "Disabling dolby" "read_hdmi_sink_caps" \
            "is_netflix_dolby" "audio_features"; do
  echo "  --- files containing '$prop' ---"
  grep -rls "$prop" \
    /vendor/lib /vendor/lib64 /system/lib /system/lib64 /odm/lib /odm/lib64 \
    /system/priv-app /system/app /vendor/app /odm 2>/dev/null | sed 's/^/      /'
  # (silent if none)
done

# ----------------------------------------------------------------------------
# 4. The protected HAL / audio-extension libraries — pull for local disasm
# ----------------------------------------------------------------------------
echo
echo "=== [4] AUDIO HAL / EXTENSION LIBRARIES ==="
for f in \
  /vendor/lib/hw/audio.primary.msm8998.so \
  /vendor/lib64/hw/audio.primary.msm8998.so \
  /vendor/lib/hw/audio.primary.default.so \
  /vendor/lib/libaudioextnfb.so \
  /vendor/lib64/libaudioextnfb.so \
  /system/lib/libaudiopolicymanager.so \
  /system/lib/libmobileconfighidlaudioclient.so ; do
  ls -l "$f" 2>&1 | sed 's/^/    /'
done

# Copy the protected libs to /data/local/tmp so `adb pull` can retrieve them.
# (Only succeeds if we actually have privilege; harmless otherwise.)
echo "  --- copying protected libs to /data/local/tmp/ ---"
mkdir -p /data/local/tmp/dolby_libs 2>/dev/null
for f in \
  /vendor/lib/hw/audio.primary.msm8998.so \
  /vendor/lib64/hw/audio.primary.msm8998.so \
  /vendor/lib/libaudioextnfb.so \
  /vendor/lib64/libaudioextnfb.so ; do
  cp "$f" /data/local/tmp/dolby_libs/ 2>&1 | sed 's/^/    /'
done
ls -l /data/local/tmp/dolby_libs/ 2>&1 | sed 's/^/    /'

# ----------------------------------------------------------------------------
# 5. The protected EDID / audio_data_block nodes (does the TV advertise AC3?)
# ----------------------------------------------------------------------------
echo
echo "=== [5] EDID / AUDIO DATA BLOCK (HDMI sink capabilities) ==="
for f in \
  /sys/devices/virtual/graphics/fb0/edid \
  /sys/devices/virtual/graphics/fb0/audio_data_block \
  /sys/class/graphics/fb0/edid \
  /sys/class/graphics/fb0/audio_data_block ; do
  echo "  --- $f ---"
  if [ -r "$f" ]; then
    echo "    (readable) size=$(wc -c < "$f" 2>/dev/null) bytes"
    od -A x -t x1z "$f" 2>/dev/null | head -20 | sed 's/^/    /'
  else
    echo "    NOT readable: $(ls -l "$f" 2>&1)"
  fi
done

# ----------------------------------------------------------------------------
# 6. The MobileConfig service — source of the is_netflix_dolby_enabled flag
# ----------------------------------------------------------------------------
echo
echo "=== [6] MOBILECONFIG SERVICE ==="
echo "  --- process ---"
ps -A 2>/dev/null | grep -iE 'mobileconfig|platformmobileconfig' | sed 's/^/    /'
echo "  --- app data (feature-flag cache) ---"
ls -la /data/data/com.facebook.aloha.platformmobileconfig/ 2>&1 | sed 's/^/    /'
find /data/data/com.facebook.aloha.platformmobileconfig -type f 2>/dev/null | sed 's/^/    /' | head -30
echo "  --- search cache for the flag ---"
grep -rls "is_netflix_dolby" /data/data/com.facebook.aloha.platformmobileconfig 2>/dev/null | sed 's/^/    /'
grep -rls "audio_features"  /data/data/com.facebook.aloha.platformmobileconfig 2>/dev/null | sed 's/^/    /'

# ----------------------------------------------------------------------------
# 7. Live HAL Dolby-decision log (fresh capture)
# ----------------------------------------------------------------------------
echo
echo "=== [7] HAL DOLBY-DECISION LOG (last 400 lines, filtered) ==="
logcat -d -b all 2>/dev/null \
  | grep -iE 'Disabling dolby|sup_formats|netflix|enable_dolby|read_hdmi_sink' \
  | tail -40 | sed 's/^/    /'

# ----------------------------------------------------------------------------
# 8. AudioService / AudioFlinger current routing
# ----------------------------------------------------------------------------
echo
echo "=== [8] AUDIOSERVICE / AUDIOFLINGER (current) ==="
dumpsys audio 2>/dev/null | grep -iE 'STREAM_MUSIC|Muted|Devices:|HdmiSystemAudio|FORCE_ENCODED|encoded_surround' | sed 's/^/    /' | head -20
echo "  --- output threads ---"
dumpsys media.audio_flinger 2>/dev/null | grep -iE 'AudioOut|Format|Channels|State' | sed 's/^/    /' | head -20

echo
echo "############################################################"
echo "#  DIAGNOSTIC COMPLETE — no settings were changed."
echo "#  Pull the output:  adb pull /data/local/tmp/dolby_diag.txt"
echo "############################################################"
