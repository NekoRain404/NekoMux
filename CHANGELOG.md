# Changelog

## 2.0.0-beta.1 - 2026-10-11

The first beta. Between 1.0.0 and here the app was audited end to end — 57
defects found, 52 fixed — and grew the things a server tool is expected to have
beyond a terminal: file transfer, containers, batch operations, and the
diagnostics that say what a machine is actually doing.

### Added

**Files**
- Upload and download over SFTP, streamed rather than buffered.
- Resume an interrupted transfer instead of starting over.
- Download a whole folder, delivered as one archive.
- Delete a folder, which the app could not do at all.
- Change a file's permission bits.
- Upload every file that was picked, asking before replacing an existing one.
- Tell a failed listing apart from a connection that ended.

**Terminal**
- Paste, and a terminal that follows the app theme.
- Search the scrollback.
- Long sessions are kept alive rather than left to time out.

**Hosts**
- Group and search the host list.
- A host is online, offline, or not yet verified — never a guess.
- Reach a host through a bastion.
- A screen for the host keys this device trusts.

**Containers**
- See what a container actually is: `docker inspect` detail, including the
  daemon's own explanation of why it stopped.
- Live CPU and memory per container.
- Manage images — list, pull, remove, and reclaim the dangling ones.
- Create a container from a form that cannot build a bad command.
- A shell inside a container, and disk usage on the console.

**Batch operations**
- Run one command across many hosts.
- Send one local file to many hosts.

**Diagnostics**
- Find out what is filling the disk, and drill into any directory.
- A disk card that shows the fullest filesystems first.

**Network**
- Port forwarding, verified through a real tunnel on a phone.

**Interface**
- A real launcher icon, drawn from the same source as the in-app mark.
- Settings that report failure instead of failing quietly.
- Eight languages, applied at launch and remembered.

### Fixed

- Host key verification, which was skipped entirely at six connection points.
- Restoring a backup silently dropped every host and snippet.
- Editing a credential spliced the placeholder text into the real secret.
- Switching authentication type reused the previous secret, storing a credential
  whose type and contents disagreed.
- Exporting a backup wrote plaintext passwords and private keys to the system
  clipboard.
- Android auto-backup was not disabled, so a restore could resurrect a database
  whose keys no longer existed.
- `free -m` failed to parse outside an English locale; memory always read 0%.
- `parseSystemctl` discarded every failed unit, making the "failed" filter and
  its count meaningless.
- A rejected remote write hung the upload and wedged that host's queue.
- Two in-flight leaks that left authenticated sessions nothing could close.
- The remote PTY did not resize with the on-screen terminal.
- The saved language was not applied at launch.
- Typefaces were fetched from Google at startup; they now ship with the app.
- Four more waves of audit findings beyond the above.

### Engineering

- Every source file is under 800 lines.
- The test suite went from 0 to 717 tests, including on-device suites that assert
  on bytes through a real SSH session rather than through a fake.
- The two modules that fabricated plausible output were deleted rather than
  repaired.

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
