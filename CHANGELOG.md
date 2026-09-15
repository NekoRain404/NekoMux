# Changelog

## 1.0.0+1 - 2026-06-09

### Added

- Built release APKs split by Android ABI:
  - `arm64-v8a`
  - `armeabi-v7a`
  - `x86_64`
- Added local release signing configuration and generated a NekoMux release
  keystore for publishable APKs.
- Added SHA-256 checksum file for release artifacts.
- Added project management documentation:
  - architecture notes;
  - release process;
  - maintenance notes.

### Fixed

- Host online status now probes real SSH reachability.
- Host console now uses real `/proc/stat` and `free -m` resource data.
- RAM chart line now renders as a live dashed series instead of staying at zero.
- Root back behavior now requires two back actions within two seconds to exit.
- Drawer navigation no longer clears the full navigation stack unexpectedly.

### Verified

- `flutter analyze` passed.
- Release build completed for all three Android ABIs.
- APK signatures verified with Android SDK `apksigner`.
- `arm64-v8a` APK installed on a real Android device.
