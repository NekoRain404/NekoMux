// The container detail model, and the parser for `docker inspect` output.
//
// `docker inspect` prints several kilobytes of nested JSON per container. On a
// phone there is no `jq` to pull a field out of it, and the interesting facts —
// why a container died, what it mounts, how it is configured — are exactly the
// ones a phone user needs at 3am. So the daemon is asked for a flat, delimited
// report instead, via a `--format` template, and [parseContainerDetail] reads it.
//
// The delimiter is a TAB, and that is not a stylistic choice: the field that
// matters most, `.State.Error`, contains the reason a container could not start
// and routinely contains a literal `|` (runc reports `flags=MS_BIND|MS_REC`).
// A pipe-delimited template would split that field in half at the exact moment
// it is the only thing on screen worth reading.

/// The `docker inspect --format` template whose output [parseContainerDetail]
/// reads.
///
/// One header line per container, then one line per mount, environment variable
/// and network, each prefixed by its kind. `docker inspect` accepts several
/// container names at once, so a single call returns a whole list — and the
/// prefix is what keeps the sections of one container from running into the
/// next.
const String dockerInspectTemplate =
    r'{{.Name}}{{"\t"}}{{.State.Status}}{{"\t"}}{{.State.ExitCode}}'
    r'{{"\t"}}{{.State.OOMKilled}}{{"\t"}}{{.RestartCount}}'
    r'{{"\t"}}{{.HostConfig.RestartPolicy.Name}}{{"\t"}}{{.Config.Image}}'
    r'{{"\t"}}{{.HostConfig.Memory}}'
    r'{{"\t"}}{{if .State.Health}}{{.State.Health.Status}}{{else}}-{{end}}'
    r'{{"\t"}}{{.State.StartedAt}}{{"\t"}}{{.State.FinishedAt}}'
    r'{{"\t"}}{{.State.Error}}{{"\n"}}'
    r'{{range .Mounts}}MOUNT{{"\t"}}{{.Type}}{{"\t"}}{{.Source}}'
    r'{{"\t"}}{{.Destination}}{{"\t"}}{{.Mode}}{{"\t"}}{{.RW}}{{"\n"}}{{end}}'
    r'{{range .Config.Env}}ENV{{"\t"}}{{.}}{{"\n"}}{{end}}'
    r'{{range $k, $v := .NetworkSettings.Networks}}NET{{"\t"}}{{$k}}'
    r'{{"\t"}}{{$v.IPAddress}}{{"\n"}}{{end}}';

/// The command that reads [container]'s full configuration.
///
/// The name is used unquoted for the same reason the lifecycle commands do it:
/// it comes from `docker ps` itself, and Docker container names cannot contain
/// shell metacharacters. The template IS quoted — it is full of braces, quotes
/// and backslashes, and single quotes are safe around it because it contains no
/// single quote of its own.
String dockerDetailCommand(String container) =>
    "docker inspect --format '$dockerInspectTemplate' $container";

/// One bind mount or volume attached to a container.
class ContainerMount {
  /// `bind`, `volume` or `tmpfs`.
  final String type;

  /// Host path, or the volume's path inside `/var/lib/docker`.
  final String source;

  /// Where it appears inside the container.
  final String destination;

  /// `ro`, `rw`, or empty when the daemon reported no mode.
  final String mode;

  /// Whether the container may write to it.
  final bool writable;

  const ContainerMount({
    required this.type,
    required this.source,
    required this.destination,
    required this.mode,
    required this.writable,
  });

  /// Whether this mount is attached read-only.
  bool get isReadOnly => !writable;
}

/// One environment variable, and whether its value looks like a secret.
class ContainerEnvVar {
  /// The name to the left of the first `=`.
  final String key;

  /// Everything to the right of the first `=`, which may be empty.
  final String value;

  /// Whether [value] is hidden until the user asks to see it.
  final bool sensitive;

  const ContainerEnvVar({
    required this.key,
    required this.value,
    required this.sensitive,
  });
}

/// One network a container is attached to.
class ContainerNetwork {
  /// Network name (`bridge`, `host`, or a compose project's network).
  final String name;

  /// The container's address on it, or empty when the daemon has none to give.
  final String address;

  const ContainerNetwork({required this.name, required this.address});
}

/// Everything the detail view shows about one container.
class ContainerDetail {
  /// Container name, with the leading `/` that `docker inspect` prints removed.
  final String name;

  /// The daemon's own word: `running`, `exited`, `created`, `paused`,
  /// `restarting` or `dead`. Kept raw rather than localised here — this file
  /// holds no UI strings, and the page decides what to call each state.
  final String status;

  /// The exit status of the last run. Only meaningful when not running, and
  /// `null` when the daemon did not report one.
  final int? exitCode;

  /// Whether the kernel killed it for using too much memory.
  final bool oomKilled;

  /// How many times the restart policy has restarted it.
  final int restartCount;

  /// `no`, `always`, `unless-stopped` or `on-failure`.
  final String restartPolicy;

  /// The image it was created from, as `docker inspect` reports it.
  final String image;

  /// Memory limit in bytes; `0` means unlimited.
  final int memoryLimitBytes;

  /// `healthy`, `unhealthy`, `starting`, or `null` when no healthcheck exists.
  final String? health;

  /// When it last started, or `null` if it never has.
  final DateTime? startedAt;

  /// When it last stopped, or `null` if it never has.
  final DateTime? finishedAt;

  /// The daemon's explanation of why it could not run — runc's mount failure,
  /// an OCI error, and so on. Empty when there is nothing wrong.
  final String stateError;

  final List<ContainerMount> mounts;
  final List<ContainerEnvVar> env;
  final List<ContainerNetwork> networks;

  const ContainerDetail({
    required this.name,
    required this.status,
    required this.exitCode,
    required this.oomKilled,
    required this.restartCount,
    required this.restartPolicy,
    required this.image,
    required this.memoryLimitBytes,
    required this.health,
    required this.startedAt,
    required this.finishedAt,
    required this.stateError,
    required this.mounts,
    required this.env,
    required this.networks,
  });

  /// Whether the daemon reports this container as up.
  bool get isRunning => status == 'running';

  /// Whether the memory limit is unlimited.
  bool get memoryUnlimited => memoryLimitBytes <= 0;

  /// Whether the daemon explained a failure that stopped it from running.
  ///
  /// This is the field a phone cannot otherwise reach: `docker ps` shows
  /// `Exited (127) 3 weeks ago` and nothing else, while the reason — a bind
  /// mount of a directory onto a file, say — is only ever in here.
  bool get hasStateError => stateError.trim().isNotEmpty;
}

/// The environment-variable names whose values are hidden by default.
///
/// A heuristic, and only that: it matches on the *name*, so a secret stored
/// under an innocuous name is not caught, and a harmless variable that happens
/// to contain `KEY` is hidden anyway. The cost of the two errors is not
/// symmetric — a value hidden that did not need hiding costs one tap, while a
/// credential rendered onto a screen that is about to be screenshotted or shown
/// to someone cannot be taken back — so it errs towards hiding. The view offers
/// an explicit reveal, which is the only thing that makes hiding honest rather
/// than a claim the app can see into a string.
final RegExp _sensitiveEnvName = RegExp(
  r'(SECRET|TOKEN|PASSWORD|PASSWD|PWD|KEY|CREDENTIAL|AUTH|PRIVATE|CERT|SALT|SEED)',
);

/// A URL carrying credentials in its userinfo: `scheme://user:secret@host`.
///
/// This exists because name-matching alone is not enough, and the counterexample
/// is on this machine rather than hypothetical:
///
///     DATABASE_URL=postgresql://nekoagent:a523967796c0ab70…@postgres:5432/db
///
/// The name contains none of the words above, and the value is a live password
/// for a database on a network the container can reach. Connection strings are
/// the single most common way a credential reaches an environment variable, and
/// a heuristic that reads only the name misses all of them.
///
/// The password part is required: `https://example.com/path` has a userinfo-less
/// authority and is not a secret, while `https://token@host` is.
final RegExp _credentialInUrl = RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://[^/@\s]+@');

/// Whether [name] looks like the name of a secret.
bool looksLikeSecretEnvName(String name) =>
    _sensitiveEnvName.hasMatch(name.toUpperCase());

/// Whether the variable [name]=[value] should be hidden until asked for.
///
/// Both halves are checked, because either one alone misses real credentials:
/// names catch `API_TOKEN=abc`, and values catch the connection strings above.
bool looksLikeSecret(String name, String value) =>
    looksLikeSecretEnvName(name) || _credentialInUrl.hasMatch(value.trim());

/// Reads the output of [dockerDetailCommand] into one detail per container.
///
/// Returns a list because `docker inspect` accepts several names in one call.
/// A container whose header line is malformed is skipped rather than guessed
/// at — the same rule the `docker ps` parser follows, and for the same reason:
/// a half-read row would show a wrong name, and every action is issued against
/// the name.
List<ContainerDetail> parseContainerDetail(String output) {
  final details = <ContainerDetail>[];
  _Builder? current;

  for (final line in output.split('\n')) {
    if (line.isEmpty) continue;
    final parts = line.split('\t');

    switch (parts.first) {
      case 'MOUNT':
        // Fewer than six fields means a source path held a tab and shifted the
        // rest; the row is dropped rather than shown with a wrong destination.
        if (current != null && parts.length >= 6) {
          current.mounts.add(
            ContainerMount(
              type: parts[1],
              source: parts[2],
              destination: parts[3],
              mode: parts[4],
              writable: parts[5] == 'true',
            ),
          );
        }
      case 'ENV':
        if (current != null && parts.length >= 2) {
          // Rejoined rather than taken as `parts[1]`: an environment value may
          // itself contain a tab, and splitting it off would truncate the value
          // at the first one.
          final entry = parts.sublist(1).join('\t');
          final at = entry.indexOf('=');
          final key = at < 0 ? entry : entry.substring(0, at);
          final value = at < 0 ? '' : entry.substring(at + 1);
          current.env.add(
            ContainerEnvVar(
              key: key,
              value: value,
              sensitive: looksLikeSecret(key, value),
            ),
          );
        }
      case 'NET':
        if (current != null && parts.length >= 3) {
          // A stopped container reports the literal string `invalid IP` here.
          // It is not an address and must not be shown as one.
          final address = parts[2].trim();
          current.networks.add(
            ContainerNetwork(
              name: parts[1],
              address: address == 'invalid IP' ? '' : address,
            ),
          );
        }
      default:
        if (parts.length < 12) {
          current = null;
          continue;
        }
        current = _Builder(parts);
        details.add(current.build());
    }
  }

  return details;
}

/// Accumulates one container's sections while its lines are being read.
class _Builder {
  final List<String> header;
  final List<ContainerMount> mounts = [];
  final List<ContainerEnvVar> env = [];
  final List<ContainerNetwork> networks = [];

  _Builder(this.header);

  ContainerDetail build() => ContainerDetail(
    name: header[0].startsWith('/') ? header[0].substring(1) : header[0],
    status: header[1],
    exitCode: int.tryParse(header[2]),
    oomKilled: header[3] == 'true',
    restartCount: int.tryParse(header[4]) ?? 0,
    restartPolicy: header[5],
    image: header[6],
    memoryLimitBytes: int.tryParse(header[7]) ?? 0,
    health: header[8] == '-' ? null : header[8],
    startedAt: parseDockerTime(header[9]),
    finishedAt: parseDockerTime(header[10]),
    // The last field, rejoined: runc's mount errors are long, and rejoining
    // costs nothing while a stray tab in one would otherwise cut the sentence
    // off before it says what went wrong.
    stateError: header.sublist(11).join('\t'),
    mounts: mounts,
    env: env,
    networks: networks,
  );
}

/// The zero time the daemon prints for a timestamp that never happened.
const String _dockerZeroTime = '0001-01-01T00:00:00Z';

/// Parses a Docker timestamp, or `null` when there is no real one.
///
/// The daemon prints nanoseconds (`2026-09-18T16:18:28.066491896Z`) and
/// [DateTime.parse] keeps microseconds, truncating the last three digits on its
/// own — checked against the SDK rather than assumed, because the alternative
/// was a dozen lines of manual fraction-slicing that never ran. Nothing in this
/// view compares at sub-microsecond precision, so the truncation costs nothing.
///
/// The one shape that does need handling is a container that has never started:
/// it reports `0001-01-01T00:00:00Z`, Go's zero time, which [DateTime.parse]
/// accepts happily and which would otherwise render as the year 1.
DateTime? parseDockerTime(String raw) {
  final text = raw.trim();
  if (text.isEmpty || text == _dockerZeroTime) return null;
  return DateTime.tryParse(text);
}
