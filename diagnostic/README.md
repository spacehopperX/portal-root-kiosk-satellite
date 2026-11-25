# Dolby Gate Diagnostic — Portal TV (ripley)

A **read-only** diagnostic to pin down exactly what controls the audio HAL's
`read_hdmi_sink_caps` → `Disabling dolby formats` branch on Portal TV
(`ripley`, Android 9 / API 28, Qualcomm msm8998, build `2041515800015050`).

## What we know so far (verified on-device via ADB)

| Layer | Finding |
|:--|:--|
| HAL filter | `libaudioextnfb.so` (SELinux-protected) logs `Disabling dolby formats`; supported = `DTS\|IEC61937\|PCM` (no AC3/E-AC3). |
| Framework gate | `libaudiopolicymanager.so` (readable) contains `"Dolby for Netflix mobile config is %d, Setting %s property to %s"` + `persist.audio.netflix.dolby.enabled` + `portal_mobileconfig_audio_features:is_netflix_dolby_enabled`. |
| Source of truth | The flag is served by Meta's **MobileConfig** service (`com.facebook.aloha.platformmobileconfig`), which *writes* `persist.audio.netflix.dolby.enabled`. |
| ADB write | Both `persist.audio.netflix.dolby.enabled` and `persist.vendor.audio.enable_dolby` are SELinux-gated → `setprop` returns `0x18`. The vendor `enable_dolby` is currently **empty**. |

**Key uncertainty this diagnostic resolves:** does the HAL read
`persist.audio.netflix.dolby.enabled` **or** the (currently empty)
`persist.vendor.audio.enable_dolby`? And does the connected Samsung TV
actually advertise AC3 Short Audio Descriptors in its EDID?

## Files

- `portal_dolby_diag.sh` — the diagnostic script. Performs **zero writes**.
  It is safe to run as plain `sh` (protected reads just fail with
  `Permission denied`, which is informative), but it is *most useful* run
  inside the `ripley` temporary-privileged window so the protected HAL libs
  and EDID nodes are readable.

## How to run

### A. Without the exploit (ordinary ADB) — partial results

```bash
SER=821PGR01P0100C15   # your USB serial
adb -s $SER push diagnostic/portal_dolby_diag.sh /data/local/tmp/
adb -s $SER shell 'sh /data/local/tmp/portal_dolby_diag.sh'
adb -s $SER pull /data/local/tmp/dolby_diag.txt
```

Sections [0]–[2] and [7]–[8] will succeed. Sections [3]–[6] (protected
reads) will show `Permission denied` — that's expected and still useful.

### B. Inside the `ripley` temporary-privileged window — full results

Build only the preload `.so` (requires the Android NDK; on macOS override
`TOOLCHAIN=darwin-x86_64`):

```bash
cd exploit
make TOOLCHAIN=darwin-x86_64 preload-portal-ripley-2041515800015050.so
```

Push both the `.so` and the script, then run the script *through* the
exploit so its constructor elevates the `sh` process before the script's
`main()` runs:

```bash
adb -s $SER push exploit/preload-portal-ripley-2041515800015050.so /data/local/tmp/
adb -s $SER push diagnostic/portal_dolby_diag.sh /data/local/tmp/
adb -s $SER shell 'LD_PRELOAD=/data/local/tmp/preload-portal-ripley-2041515800015050.so sh /data/local/tmp/portal_dolby_diag.sh'
adb -s $SER pull /data/local/tmp/dolby_diag.txt
```

> **Safety:** the `ripley` target uses `CONFIGFS_ROOT_CRED_SID_ONLY` — it
> elevates the single target process to `uid=0`/`init` SID and leaves
> **SELinux enforcing globally**. When that `sh` process exits (or the
> Portal reboots), no root binary or system modification remains. This
> script writes nothing persistent. If anything looks off, **reboot the
> Portal** to fully clear the privileged state.

## Interpreting the output

- **Section [3]** is the crux. If `netflix.dolby` appears in
  `libaudioextnfb.so` (or `audio.primary.msm8998.so`), the HAL is gated by
  the Netflix property → the fix is to keep that property `true` *and*
  prevent MobileConfig from overwriting it. If only `enable_dolby` appears,
  the vendor property is the real gate.
- **Section [5]** confirms whether the Samsung EDID actually advertises AC3.
  If the TV omits it, no property change will help — the sink itself is the
  limit.
- **Section [6]** reveals the MobileConfig cache format, so we can decide
  whether to stop the service, or write the property after its last refresh.

## Rollback / cleanup

Nothing persistent is changed. To remove the working files:

```bash
adb -s $SER shell 'rm -f /data/local/tmp/portal_dolby_diag.sh /data/local/tmp/dolby_diag.txt; rm -rf /data/local/tmp/dolby_libs'
```
