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

If Gradle is using a stale proxy from `~/.gradle/gradle.properties`, build
directly with a known working proxy:

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
