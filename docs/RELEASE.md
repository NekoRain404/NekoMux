# Release Process

This document records how to build, verify, and install NekoMux release APKs.

## Release Metadata

Current release:

- App id: `com.nekomux.neko_mux`
- Version name: `1.0.0`
- Pubspec version: `1.0.0+1`
- Split APK version codes:
  - `armeabi-v7a`: `1001`
  - `arm64-v8a`: `2001`
  - `x86_64`: `4001`

## Signing Files

Signing config is loaded from:

```text
android/key.properties
```

Expected fields:

```properties
storeFile=/absolute/path/to/release-keystore.jks
storePassword=...
keyAlias=nekomux
keyPassword=...
```

The current local release key files are:

```text
android/key.properties
android/nekomux-release.jks
```

They are intentionally ignored by `.gitignore`. Back them up separately and
keep them private. Future updates must use the same keystore to update installed
release builds.

Current certificate SHA-256:

```text
951124b7ec0139c0dd2bd89d5976f912b671d8b04ba5bed1fbeab16f1cc1de51
```

## Build

Preferred Flutter command:

```bash
/home/nekorain/Projects/flutter/bin/flutter build apk --release --split-per-abi
```

If Gradle reads a stale proxy from `~/.gradle/gradle.properties`, use direct
Gradle build with explicit proxy override:

```bash
android/gradlew -p android --no-daemon \
  -Dhttp.proxyHost=127.0.0.1 -Dhttp.proxyPort=7890 \
  -Dhttps.proxyHost=127.0.0.1 -Dhttps.proxyPort=7890 \
  app:assembleRelease \
  -Ptarget-platform=android-arm,android-arm64,android-x64 \
  -Psplit-per-abi=true \
  -Ptarget=/home/nekorain/AndroidStudioProjects/NekoMux/lib/main.dart \
  -Ptree-shake-icons=true \
  -Ptrack-widget-creation=false
```

## Copy Release Outputs

```bash
mkdir -p dist
cp build/app/outputs/flutter-apk/app-arm64-v8a-release.apk \
  dist/NekoMux-v1.0.0+1-arm64-v8a-release.apk
cp build/app/outputs/flutter-apk/app-armeabi-v7a-release.apk \
  dist/NekoMux-v1.0.0+1-armeabi-v7a-release.apk
cp build/app/outputs/flutter-apk/app-x86_64-release.apk \
  dist/NekoMux-v1.0.0+1-x86_64-release.apk
sha256sum dist/NekoMux-v1.0.0+1-*-release.apk > dist/SHA256SUMS.txt
```

## Verify

Use Android SDK build tools:

```bash
/home/nekorain/Android/Sdk/build-tools/37.0.0/apksigner verify \
  --verbose --print-certs dist/NekoMux-v1.0.0+1-arm64-v8a-release.apk
```

Expected result:

- `Verifies`
- `Verified using v2 scheme`: `true`
- signer certificate SHA-256 matches the release certificate above

Check ABI and version:

```bash
/home/nekorain/Android/Sdk/build-tools/37.0.0/aapt dump badging \
  dist/NekoMux-v1.0.0+1-arm64-v8a-release.apk
```

Expected for the 64-bit phone package:

- `native-code: 'arm64-v8a'`
- `versionName='1.0.0'`
- `versionCode='2001'`

## Install On A 64-Bit Android Device

```bash
adb shell getprop ro.product.cpu.abi
adb install -r dist/NekoMux-v1.0.0+1-arm64-v8a-release.apk
```

If Android reports `INSTALL_FAILED_UPDATE_INCOMPATIBLE`, the installed package
was signed with a different key. Uninstalling fixes it but clears app data:

```bash
adb uninstall com.nekomux.neko_mux
adb install dist/NekoMux-v1.0.0+1-arm64-v8a-release.apk
```
