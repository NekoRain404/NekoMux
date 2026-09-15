# Architecture

This document defines the current module boundaries for NekoMux. Keep new work
inside these boundaries unless a feature clearly needs a new layer.

## Layer Map

```text
UI pages -> providers -> services/database -> external systems
widgets  -> presentation-only reusable components
models   -> serializable data structures
core     -> app-wide infrastructure
```

## Core Responsibilities

`lib/pages`

Screens own navigation, lifecycle, and user interaction. They should not own
long-lived protocol behavior unless the behavior is specific to that screen.

Examples:

- `home_page.dart` schedules host reachability probes and renders grouped hosts.
- `host_console_page.dart` owns the host detail workflow and starts monitoring
  while the page is visible.
- `ssh_terminal_page.dart` owns the terminal interaction surface.

`lib/services`

Services own protocol and parsing behavior. They should avoid importing Flutter
UI classes.

Examples:

- `ssh_service.dart` wraps `dartssh2` connection lifecycle.
- `sftp_service.dart` wraps remote file browsing and transfer behavior.
- `monitoring_service.dart` parses `/proc/stat`, `free`, `ps`, and `systemctl`
  output. Parsing belongs here so charts and pages do not duplicate shell
  parsing rules.

`lib/providers`

Providers bridge persistent storage and UI state. They are the right place for
state invalidation, SQLite reads/writes, and secure-storage migration.

Examples:

- `CredentialListNotifier` reads credentials from SQLite and retrieves secrets
  from secure storage.
- `HostListNotifier` enriches hosts with credential display data and updates
  volatile online state without a database round trip.

`lib/widgets`

Widgets are reusable presentation components. They should receive ready-to-render
data and callbacks rather than reaching into SSH, SQLite, or secure storage.

Examples:

- `resource_chart.dart` receives CPU/RAM `FlSpot` lists and only renders chart
  lines.
- `host_card.dart` renders one host row/card.
- `app_ui.dart` contains common card, section, and empty-state pieces.

`lib/models`

Models represent data shape and serialization. Keep them lightweight.

## Coupling Rules

- Pages may depend on providers, models, services, and widgets.
- Providers may depend on database, secure storage, and models.
- Services may depend on models and third-party protocol libraries.
- Widgets may depend on Flutter, theme, and models, but should not call SSH or
  database APIs directly.
- Models should not depend on pages, widgets, providers, or services.

## Monitoring Flow

The live resource chart is intentionally split:

1. `HostConsolePage` owns page lifecycle and polling timer.
2. `SshConnection` owns the SSH connection and command execution.
3. `MonitoringService` parses Linux command output into numeric values.
4. `ResourceChart` renders the provided CPU/RAM data series.

This keeps protocol details out of the chart widget and keeps drawing details
out of the monitoring parser.

## Notes For Future Refactoring

The next useful extraction is a `HostMonitorController` or Riverpod notifier
that owns monitoring state, polling, and connection retry behavior. That would
move more logic out of `HostConsolePage` while preserving the same UI.

Avoid extracting this too early: the current page-level ownership is still
reasonable while monitoring is only used by one screen.
