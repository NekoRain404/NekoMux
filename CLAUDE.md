# NekoMux — project conventions

Working notes for anyone (human or agent) changing this codebase. Keep this file
short and about rules, not status.

## Hard rules

**No source file may exceed 800 lines.** This applies to every `.dart` file
under `lib/`. When a file approaches the limit, split it by responsibility
before adding to it — extract a service, a widget, or a set of pure helpers into
their own file. Do not split by copying a block out and leaving the rest behind;
move a coherent unit.

**Run `flutter analyze` and `flutter test` before claiming a change works.** Both
must be clean. The project had zero tests until 2026-09-15; new logic that can be
tested in isolation should get a test.

**Never commit signing material.** `android/key.properties`, `android/*.jks` and
`android/*.keystore` are gitignored. They are the release key — losing it means
future APKs cannot update installed releases. Before any `git add -A`, confirm
with `git status --ignored` that they are still ignored.

## Current size violations

Tracked here so the constraint does not silently rot. As of 2026-09-15:

| File | Lines | Suggested split |
| --- | --- | --- |
| `lib/core/i18n/strings.dart` | 3465 | One file per language; it is a pure data table with 8 languages |
| `lib/pages/sftp_page.dart` | 1182 | Path/breadcrumb logic; selection + batch actions; file dialogs |
| `lib/pages/settings_page.dart` | 1041 | Backup/restore into `backup_service.dart`; appearance; data management |
| `lib/pages/container_shell_page.dart` | 1019 | Docker command layer; container list; log viewer |
| `lib/pages/host_console_page.dart` | 843 | Monitoring into a `hostMonitorProvider` |

`lib/pages/wireless_adb_page.dart` (789) and `lib/pages/systemd_page.dart` (731)
are close to the limit — check before adding to them.

## Architecture

Documented in `docs/ARCHITECTURE.md` (layer map, coupling rules) and
`docs/MAINTENANCE.md` (code health, monitoring rules). Follow them rather than
re-deriving the structure.

- Pages → providers → services/database. Widgets stay presentation-only.
- Parsing and protocol behaviour belongs in `lib/services`, never in a page.
- Models stay free of Flutter and service dependencies. Do not put UI strings in
  a model — see `lib/models/file_item.dart`, which currently does and should not.

## Secrets

Credentials live in `flutter_secure_storage` (Android Keystore-backed). The
SQLite row stores only the literal `'secure_storage'` as a placeholder. Anything
that moves a secret out of that store — export, backup, sharing — must be
explicit about it and must not route it through the system clipboard.

Android auto-backup is disabled (`android:allowBackup="false"` plus
`res/xml/data_extraction_rules.xml`). Keystore keys are device-bound and are not
backed up, so a restore that resurrects the database without its keys leaves
every credential undecryptable and the host list unloadable. Do not re-enable
either path.

## Open audit

`docs/AUDIT-2026-09-15.html` lists 57 verified defects with `file:line` and fix
direction, ordered by severity, with the recommended fix order at the end. Check
items off there as they are addressed.
