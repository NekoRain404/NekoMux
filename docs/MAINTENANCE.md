# Maintenance Notes

These notes are for keeping the project understandable as it grows.

## Code Health Rules

- Keep UI rendering in widgets and pages.
- Keep parsing and protocol logic in services.
- Keep persistence state in providers.
- Keep models free from UI and service dependencies.
- Add comments where behavior is non-obvious, not beside every line.

## Current Strengths

- Credentials and hosts are separated, which avoids repeating secrets per host.
- SSH connection lifecycle is wrapped in `SshConnection`.
- Monitoring parsing is centralized in `MonitoringService`.
- `ResourceChart` is presentation-only and does not know about SSH.
- Release ABI outputs are separated and verified.

## Known Coupling Points

`HostConsolePage`

This page currently owns UI, SSH monitoring lifecycle, polling timer, error
fallback, and chart buffer updates. That is acceptable for the current single
screen, but it should be extracted if monitoring is reused elsewhere.

Recommended future shape:

```text
HostConsolePage -> hostMonitorProvider -> SshConnection + MonitoringService
```

`HomePage`

Home currently probes hosts directly through SSH. This makes the behavior easy
to follow, but it couples list rendering to reachability probing.

Recommended future shape:

```text
HomePage -> hostReachabilityProvider -> SshConnection
```

`providers.dart`

All main list providers live in one file. It is still readable, but once more
entities are added, split by domain:

```text
providers/database_providers.dart
providers/credential_providers.dart
providers/host_providers.dart
providers/snippet_providers.dart
```

## Monitoring Rules

Prefer stable Linux sources:

- CPU: `/proc/stat` sampled twice and converted through deltas.
- RAM: `free -m`, using `used / total`.

Avoid using chart data as source-of-truth. The chart is only a rendering buffer.
The latest numeric values should be stored separately, as the current code does
with `_latestCpu` and `_latestRam`.

## Release Safety Checklist

Before every public release:

- Run `flutter analyze`.
- Build split APKs.
- Verify all APK signatures with `apksigner`.
- Verify ABI and version with `aapt dump badging`.
- Update `dist/SHA256SUMS.txt`.
- Install the `arm64-v8a` build on a real device.
- Confirm `primaryCpuAbi=arm64-v8a` with `adb shell dumpsys package`.
- Keep release keystore backed up outside the project tree.

## Documentation Checklist

When a feature changes behavior, update at least one of:

- `README.md` for user-visible project summary;
- `docs/ARCHITECTURE.md` for module boundaries;
- `docs/RELEASE.md` for build/signing/install changes;
- `CHANGELOG.md` for release-level changes.
