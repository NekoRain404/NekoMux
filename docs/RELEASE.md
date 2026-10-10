# Release Process

This document records how to build, verify, and install NekoMux release APKs.

## Release Metadata

Current release: `2.0.0-beta.1` (beta)

- App id: `com.nekomux.neko_mux`
- Version name: `2.0.0-beta.1`
- Pubspec version: `2.0.0-beta.1+2003`
- Split APK version codes, read back from the built APKs with `aapt`:
  - `armeabi-v7a`: `3003`
  - `arm64-v8a`: `4003`
  - `x86_64`: `6003`

A split's version code is the pubspec build number (`2003`) plus a per-ABI
offset — 1000 for `armeabi-v7a`, 2000 for `arm64-v8a`, 4000 for `x86_64`. The
offset scheme is Flutter's; the numbers above are measured rather than
calculated, so a change in that scheme shows up as a mismatch here instead of
as a wrong expectation nobody checks.

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

If Gradle fails with `Gradle threw an error while downloading artifacts from
the network`, do not assume the proxy in `~/.gradle/gradle.properties` is good
— check that something is actually listening on its port, and test whether the
direct route works:

```bash
(ss -ltn || netstat -ltn) | grep -E '7890|7897'
curl -sS -o /dev/null -w '%{http_code}\n' \
  https://dl.google.com/dl/android/maven2/com/android/tools/build/apksigner/maven-metadata.xml
```

If that returns `200`, bypass the proxy for one build without touching the
machine-wide config:

```bash
android/gradlew -p android --no-daemon \
  -Dhttp.nonProxyHosts='*' -Dhttps.nonProxyHosts='*' \
  -Dhttp.proxyHost= -Dhttp.proxyPort= -Dhttps.proxyHost= -Dhttps.proxyPort= \
  app:assembleRelease \
  -Ptarget-platform=android-arm,android-arm64,android-x64 \
  -Psplit-per-abi=true \
  -Ptarget=/home/nekorain/AndroidStudioProjects/NekoMux/lib/main.dart \
  -Ptree-shake-icons=true \
  -Ptrack-widget-creation=false
```

If it does not, point `-Dhttps.proxyHost` / `-Dhttps.proxyPort` at the port the
proxy is really on and keep the rest of the command as-is.

Two traps: `GRADLE_OPTS` does **not** override the proxy (`systemProp.*` in
`gradle.properties` takes precedence), so the override has to be a command-line
`-D`; and `-Ptarget-platform` takes one value per ABI.

Always confirm the result with `apksigner verify --print-certs` against the
**installed** app before sideloading over it — a mismatched signing key forces
an uninstall, which wipes the user's hosts and credentials.

## Copy Release Outputs

Set `VER` once and the rest of this page follows it. The version used to be
written out in every command below, which is exactly how this document drifted
two releases behind the app without anyone noticing — a stale literal in a
command nobody re-read.

```bash
VER=v2.0.0-beta.1+2003
mkdir -p dist
for abi in arm64-v8a armeabi-v7a x86_64; do
  cp "build/app/outputs/flutter-apk/app-$abi-release.apk" \
    "dist/NekoMux-$VER-$abi-release.apk"
done
sha256sum dist/NekoMux-$VER-*-release.apk > dist/SHA256SUMS.txt
```

## Verify

Use Android SDK build tools:

```bash
VER=v2.0.0-beta.1+2003
/home/nekorain/Android/Sdk/build-tools/37.0.0/apksigner verify \
  --verbose --print-certs "dist/NekoMux-$VER-arm64-v8a-release.apk"
```

Expected result:

- `Verifies`
- `Verified using v2 scheme`: `true`
- signer certificate SHA-256 matches the release certificate above

Check ABI and version:

```bash
/home/nekorain/Android/Sdk/build-tools/37.0.0/aapt dump badging \
  "dist/NekoMux-$VER-arm64-v8a-release.apk"
```

Expected for the 64-bit phone package:

- `native-code: 'arm64-v8a'`
- `versionName='2.0.0-beta.1'`
- `versionCode='4003'`

## Install On A 64-Bit Android Device

```bash
VER=v2.0.0-beta.1+2003
adb shell getprop ro.product.cpu.abi
adb install -r "dist/NekoMux-$VER-arm64-v8a-release.apk"
```

If Android reports `INSTALL_FAILED_UPDATE_INCOMPATIBLE`, the installed package
was signed with a different key. Uninstalling fixes it but clears app data:

```bash
adb uninstall com.nekomux.neko_mux
adb install "dist/NekoMux-$VER-arm64-v8a-release.apk"
```

An install over an existing build works whenever the certificate matches the
one recorded above **and** the version code is higher. Both hold for a beta
whose build number was incremented, which is why `2.0.0-beta.1+2003` installs
over `2.0.0+2002` without an uninstall.
