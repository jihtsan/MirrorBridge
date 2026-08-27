# MirrorBridge

Native macOS control app for wireless Android screen mirroring through ADB and scrcpy.

MirrorBridge is not a Smart View/Miracast receiver. It uses Android Wireless debugging for discovery and authorization, then starts scrcpy for the actual screen mirror and computer control.

## v0.1 developer preview

This is a developer preview for a single Mac and one or more Android devices. The
supported end-to-end flow is:

- Pair with `adb pair` using the address and pairing code shown on the phone.
- Discover paired Wireless debugging devices with `adb mdns services`.
- Connect to the current dynamic ADB endpoint with `adb connect`.
- Start and stop an external scrcpy mirror window.
- Stop and reconnect without pairing again.
- Recover from missing tools, discovery errors, connection errors, and an exited
  scrcpy process through the in-app refresh/retry actions.

The app still requires the user to install `adb` and `scrcpy` locally. The mirror
is a separate scrcpy window; MirrorBridge does not embed or reimplement the
scrcpy protocol. Bundling and signing third-party binaries is outside this
preview until their versions, architecture support, checksums, and license
notices have been reviewed.

## Requirements

- macOS 13 or later
- Swift 5.9 or later
- Android 11 or later for Wireless debugging
- Android SDK Platform-Tools (`adb`)
- scrcpy
- Mac and phone connected to the same non-isolated Wi-Fi network

For local development, MirrorBridge searches the app bundle first, then common
Homebrew/Android SDK locations, and finally the user's `PATH`. If either tool is
missing, the app identifies the missing tool and the **重新检查** action retries
tool discovery without restarting the app.

## Build

```bash
swift build
./scripts/build-app.sh
open dist/MirrorBridge.app
```

The build script creates a macOS app bundle. To stage tools inside the bundle, place the verified executables in `Tools/bin/` before building:

```text
Tools/bin/adb
Tools/bin/scrcpy
Tools/bin/scrcpy-server
```

Do not commit downloaded binaries until their release version, architecture, checksums, and license notices have been reviewed.

## Signing

For local development the app can remain unsigned. For friend distribution, use a Developer ID identity and notarize the final app or DMG. The build script accepts a signing identity through `MIRRORBRIDGE_SIGNING_IDENTITY` and signs the nested tools before signing the app bundle.

```bash
MIRRORBRIDGE_SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./scripts/build-app.sh
```

## Manual real-device acceptance

Use an Android 11 or later phone with Wireless debugging enabled and record the
device model, Android version, macOS version, Mac architecture, `adb` version,
and scrcpy version with the result.

1. Open Wireless debugging on the Android phone.
2. Choose **Pair device with pairing code** and enter the displayed address and
   code in MirrorBridge.
3. Confirm the device appears after **刷新** or **重新检查**. The pairing code
   is cleared after submission and is never written to the diagnostic log.
4. Select the discovered connection endpoint and choose **连接并镜像**. Confirm
   that a separate scrcpy window opens and the phone screen is controllable.
5. Choose **停止**, confirm the window closes and the app remains usable, then
   choose **连接并镜像** again. Confirm this second connection does not invoke
   pairing.
6. Close the scrcpy window manually and confirm the app leaves the busy/mirroring
   state and allows another retry.

After pairing, opening Wireless debugging again should only require discovery and
connection. The app must not call `adb pair` again unless the phone has forgotten
or revoked the pairing.

This workspace does not have Android hardware attached, so the real-device flow
above remains an owner/Stage 3 manual check. The automated suite uses controlled
ADB and scrcpy substitutes and does not claim vendor or device compatibility.

## Known compatibility scope

- The code is intended for macOS 13 or later and uses the system `Process` API.
- Wireless debugging discovery depends on the `adb mdns services` output format
  and a network that permits mDNS and the device's dynamic ADB endpoint.
- The checked-in build has only been exercised on the local supported build host;
  no Intel Mac, Android vendor, or scrcpy release matrix is claimed here.
- Smart View/Miracast, embedded scrcpy transport, cloud relay, account systems,
  packaging, signing, notarization, and App Store distribution are not part of
  v0.1.

## Scope boundaries

- No Smart View/Miracast receiver implementation.
- No reimplementation of the scrcpy video/control protocol.
- No cloud relay or account service.
- No App Store submission in this bootstrap change.
