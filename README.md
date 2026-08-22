# MirrorBridge

Native macOS control app for wireless Android screen mirroring through ADB and scrcpy.

MirrorBridge is not a Smart View/Miracast receiver. It uses Android Wireless debugging for discovery and authorization, then starts scrcpy for the actual screen mirror and computer control.

## Current status

This repository contains the first native SwiftUI control-app skeleton:

- Pair with `adb pair` using the address and pairing code shown on the phone.
- Discover paired Wireless debugging devices with `adb mdns services`.
- Connect to the current dynamic ADB endpoint with `adb connect`.
- Start and stop a scrcpy mirror window.
- Show connection state, tool paths, and process logs.

The app still requires `adb` and `scrcpy` to be installed locally. Bundling and signing those third-party binaries is tracked separately so their versions and license notices can be verified before distribution.

## Requirements

- macOS 13 or later
- Swift 5.9 or later
- Android 11 or later for Wireless debugging
- Android SDK Platform-Tools (`adb`)
- scrcpy
- Mac and phone connected to the same non-isolated Wi-Fi network

For local development, MirrorBridge searches the app bundle first, then common Homebrew/Android SDK locations, and finally the user's `PATH`.

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

## First-use flow

1. Open Wireless debugging on the Android phone.
2. On the phone, choose **Pair device with pairing code**.
3. Enter the displayed pairing address and code in MirrorBridge.
4. Choose **Always allow on this network** if Android shows the trust prompt.
5. Select the discovered connection endpoint and choose **Connect and mirror**.

After pairing, opening Wireless debugging again should only require discovery and connection; the app must not call `adb pair` again unless the phone has forgotten or revoked the pairing.

## Scope boundaries

- No Smart View/Miracast receiver implementation.
- No reimplementation of the scrcpy video/control protocol.
- No cloud relay or account service.
- No App Store submission in this bootstrap change.
