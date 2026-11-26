# `portal_dolby_diag.sh` — read-only Dolby-gate probe for Portal TV (ripley)

## What it is

A single **zero-write** shell script that pinpoints which property/branch
controls the audio HAL's `read_hdmi_sink_caps` → `Disabling dolby formats`
filter, and whether the connected TV advertises AC3 in its EDID. It is safe to
run as plain `sh` (protected reads just fail, which is itself useful signal),
and most useful run inside the `ripley` temporary-privileged window.

It performs **no writes** and leaves no persistent changes.

## How to run

**Unprivileged (plain ADB)** — covers sections [0]–[2], [7]–[8]:

```sh
adb -s $SER push portal_dolby_diag.sh /data/local/tmp/
adb -s $SER shell sh /data/local/tmp/portal_dolby_diag.sh > dolby_diag.txt 2>&1
adb -s $SER pull /data/local/tmp/dolby_diag.txt
```

**Inside the privileged window** — covers the protected [3]–[6] sections
(protected `.so` libraries, EDID nodes, MobileConfig cache). Uses the
optional `GHOSTLOCK_DIAG_SCRIPT` exec hook in `exploit/src/main.c`:

```sh
adb -s $SER push portal_dolby_diag.sh /data/local/tmp/
adb -s $SER shell 'GHOSTLOCK_DIAG_SCRIPT=/data/local/tmp/portal_dolby_diag.sh \
    LD_PRELOAD=<exploit.so> <trigger-binary>' > dolby_diag.txt 2>&1
adb -s $SER pull /data/local/tmp/dolby_diag.txt
```

## What the unprivileged run already established (2026-11-25)

Run as `shell` (uid 2000, SELinux enforcing) on
`Facebook/ripley_prod/ripley:9/PKQ1.191202.001/2041515800015050:user/prod-keys`
(msm8998, Android 9 / API 28):

- **The controlling property is `persist.audio.netflix.dolby.enabled`**
  (currently `false`). It is the *only* string referenced by a readable
  library: `/system/lib/libaudiopolicymanager.so` and
  `/system/lib64/libaudiopolicymanager.so`.
- **`persist.vendor.audio.enable_dolby`** is **empty/unset** and SELinux-gated
  (`u:object_r:audio_vendor_dolby_enable_prop:s0`); shell `getprop` returns
  `Access denied` (audit `avc: denied { read }`). It is *not* referenced by
  any readable `.so`.
- **`persist.sys.mobileconfigutil.usePlatformMobileConfig = false`** and **no
  `platformmobileconfig` process is running**, so the MobileConfig overwrite
  risk is currently low (the flag is cached, not actively re-pushed).
- **Audio routes to `hdmi`** but all output threads are **PCM-only**
  (`AUDIO_FORMAT_PCM_16_BIT` / `PCM_FLOAT`) — no passthrough is active, which
  matches the reported "no 5.1" symptom.
- The MobileConfig flag list includes
  `portal_mobileconfig_audio_features:is_netflix_dolby_enabled` (alongside
  `is_stax_render_enabled`, `is_usb_headset_enabled`, `string_param`).

## What still needs the privileged window

- Confirm whether the **HAL itself** (`libaudioextnfb.so` /
  `audio.primary.*.so`) reads `netflix.dolby` or the vendor `enable_dolby`
  (the vendor `.so` files are SELinux-protected and unreadable as `shell`).
- Read the **protected EDID / `audio_data_block`** nodes to confirm the
  Samsung TV advertises AC3 Short Audio Descriptors.
- Dump the **MobileConfig app cache** to confirm the server value of
  `is_netflix_dolby_enabled`.

## Safety

The `ripley` target uses `CONFIGFS_ROOT_CRED_SID_ONLY` (SELinux stays
enforcing globally; elevation reverts on process exit or reboot). The
`main.c` change is an additive, env-gated hook that performs **no writes** and
is inert unless `GHOSTLOCK_DIAG_SCRIPT` is set. Reboot the Portal afterward to
fully clear any privileged state. No kiosk profile is applied; the exploit's
kernel logic is untouched.
