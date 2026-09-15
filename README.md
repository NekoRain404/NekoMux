# NekoMux

NekoMux is a Flutter-based mobile server management tool for SSH, SFTP,
host monitoring, snippets, and daily operations from an Android device.

The project is organized around practical operations:

- manage hosts and credentials separately;
- connect through SSH and SFTP;
- inspect CPU and RAM with live SSH-based polling;
- keep reusable commands in snippets;
- ship release APKs split by Android ABI.

## Current Release

- App id: `com.nekomux.neko_mux`
- Version: `1.0.0+1`
- Min SDK: `24`
- Target SDK: `36`
- Release APKs: [dist](dist)

Release outputs:

- `dist/NekoMux-v1.0.0+1-arm64-v8a-release.apk`
- `dist/NekoMux-v1.0.0+1-armeabi-v7a-release.apk`
- `dist/NekoMux-v1.0.0+1-x86_64-release.apk`
- `dist/SHA256SUMS.txt`

## Project Layout

```text
lib/
  app.dart                 Application shell and theme wiring
  main.dart                Flutter entry point
  core/                    Database, theme, i18n
  models/                  Plain data models
  pages/                   Screens and user workflows
  providers/               Riverpod state and persistence adapters
  services/                SSH, SFTP, monitoring, secure storage
  widgets/                 Reusable visual components

android/                   Android Gradle project and signing config template
dist/                      Release APK outputs
docs/                      Architecture, release, and maintenance notes
```

## Development Commands

Use the local Flutter SDK:

```bash
/home/nekorain/Projects/flutter/bin/flutter analyze
/home/nekorain/Projects/flutter/bin/flutter run
```

Build split release APKs:

```bash
/home/nekorain/Projects/flutter/bin/flutter build apk --release --split-per-abi
```

If Gradle fails with `Gradle threw an error while downloading artifacts from
the network`, check whether the proxy named in `~/.gradle/gradle.properties`
is actually listening before trusting it:

```bash
(ss -ltn || netstat -ltn) | grep -E '7890|7897'   # is anything on that port?
curl -sS -o /dev/null -w '%{http_code}\n' \
  https://dl.google.com/dl/android/maven2/com/android/tools/build/apksigner/maven-metadata.xml
```

A dead proxy there fails every dependency download with `Connect to
127.0.0.1:<port> failed: Connection refused`, and it is worth knowing that
`GRADLE_OPTS` does **not** override it — `systemProp.*` in `gradle.properties`
wins over that env var, so the override has to be on the command line.

If the direct route works (a `200` above), bypass the proxy entirely:

```bash
android/gradlew -p android --no-daemon \
  -Dhttp.nonProxyHosts='*' -Dhttps.nonProxyHosts='*' \
  -Dhttp.proxyHost= -Dhttp.proxyPort= -Dhttps.proxyHost= -Dhttps.proxyPort= \
  app:assembleRelease \
  -Ptarget-platform=android-arm64 \
  -Psplit-per-abi=true \
  -Ptarget=/home/nekorain/AndroidStudioProjects/NekoMux/lib/main.dart \
  -Ptree-shake-icons=true \
  -Ptrack-widget-creation=false
```

Otherwise point the same flags at whichever port the proxy is really on
(`-Dhttps.proxyHost=127.0.0.1 -Dhttps.proxyPort=<port>`), and keep the existing
`app:assembleRelease` and `-P` arguments unchanged.

Note `-Ptarget-platform` takes one value per ABI you want built; listing
`android-arm,android-arm64,android-x64` builds all three.

## Documentation

- [Architecture](docs/ARCHITECTURE.md)
- [Release Process](docs/RELEASE.md)
- [Maintenance Notes](docs/MAINTENANCE.md)
- [Changelog](CHANGELOG.md)

## Signing

Release signing uses `android/key.properties`, following
`android/key.properties.example`.

Never publish or commit:

- `android/key.properties`
- `android/*.jks`
- `android/*.keystore`

The current local release key is required for future app upgrades. Losing it
means future APKs cannot update already installed signed releases.
