/// What the user asked to create, before it becomes a command line.
///
/// Every field is a string because that is what a form produces, and because
/// validating here — once, explicitly — is what keeps the command builder free
/// of surprises. Nothing in this type is trusted: see [buildDockerRun].
class DockerRunSpec {
  /// The image to run, with an optional tag (`nginx:alpine`).
  final String image;

  /// `--name`, or empty for Docker to pick one.
  final String name;

  /// Published ports, one per entry, in `host:container` form.
  final List<String> ports;

  /// Volume mounts, one per entry, in `host:container` form.
  final List<String> volumes;

  /// Environment variables, one per entry, in `KEY=value` form.
  final List<String> environment;

  /// `--restart` policy: `no`, `on-failure`, `always`, `unless-stopped`.
  final String restartPolicy;

  /// Extra arguments appended verbatim, for what the form does not offer.
  ///
  /// Deliberately last and deliberately unquoted-as-one-token: the user is
  /// typing a docker argument list, and quoting the whole thing would pass it
  /// as a single argument to `docker run`, which is never what is meant. What
  /// protects the shell here is not this field — see [buildDockerRun].
  final String extraArgs;

  const DockerRunSpec({
    required this.image,
    this.name = '',
    this.ports = const [],
    this.volumes = const [],
    this.environment = const [],
    this.restartPolicy = 'unless-stopped',
    this.extraArgs = '',
  });
}

/// Why a [DockerRunSpec] cannot be turned into a command.
enum DockerRunProblem {
  /// No image was given, so there is nothing to run.
  missingImage,

  /// A value contains a character that cannot be made safe on a command line.
  unsafeValue,

  /// A port or mount is not in the `a:b` form `docker run` expects.
  malformedPair,
}

/// The result of validating: either a command to run, or what is wrong.
class DockerRunPlan {
  final String? command;
  final DockerRunProblem? problem;

  /// The offending value, for a message that names it.
  final String? offendingValue;

  const DockerRunPlan.ok(this.command)
    : problem = null,
      offendingValue = null;

  const DockerRunPlan.bad(this.problem, this.offendingValue) : command = null;

  bool get isOk => command != null;
}

/// Builds the `docker run` command for [spec], or says why it cannot.
///
/// **The quoting is the whole point of this function being separate and tested.**
/// These values come from a text field and end up in a shell on a server the
/// user may not own; a name containing `; rm -rf /` is a real possibility and a
/// builder that concatenated strings would execute it. So every value that
/// becomes an argument is single-quoted with embedded quotes escaped, which is
/// safe for any byte except a newline — and a newline is refused rather than
/// guessed at, because there is no way to pass one inside single quotes in a
/// POSIX shell and pretending otherwise is how a command injection gets in.
///
/// [DockerRunSpec.extraArgs] is the one field that is not quoted: it is an
/// argument *list* the user typed, and quoting it whole would hand `docker run`
/// a single meaningless argument. It is therefore spliced in as-is — and the
/// documentation says so, because a caller that puts remote data there would be
/// building an injection by hand.
DockerRunPlan buildDockerRun(DockerRunSpec spec) {
  final image = spec.image.trim();
  if (image.isEmpty) {
    return const DockerRunPlan.bad(DockerRunProblem.missingImage, null);
  }

  final parts = <String>['docker', 'run', '-d'];

  final name = spec.name.trim();
  if (name.isNotEmpty) {
    final safe = _quote(name);
    if (safe == null) {
      return DockerRunPlan.bad(DockerRunProblem.unsafeValue, name);
    }
    parts.addAll(['--name', safe]);
  }

  for (final port in spec.ports) {
    final trimmed = port.trim();
    if (trimmed.isEmpty) continue;
    if (!_isPair(trimmed)) {
      return DockerRunPlan.bad(DockerRunProblem.malformedPair, trimmed);
    }
    parts.addAll(['-p', _quote(trimmed)!]);
  }

  for (final volume in spec.volumes) {
    final trimmed = volume.trim();
    if (trimmed.isEmpty) continue;
    if (!_isPair(trimmed)) {
      return DockerRunPlan.bad(DockerRunProblem.malformedPair, trimmed);
    }
    parts.addAll(['-v', _quote(trimmed)!]);
  }

  for (final entry in spec.environment) {
    final trimmed = entry.trim();
    if (trimmed.isEmpty) continue;
    // `KEY=value`; a bare KEY would ask docker to copy the host's value, which
    // this app cannot do honestly — it is not on that host.
    final equals = trimmed.indexOf('=');
    if (equals <= 0) {
      return DockerRunPlan.bad(DockerRunProblem.malformedPair, trimmed);
    }
    parts.addAll(['-e', _quote(trimmed)!]);
  }

  const policies = {'no', 'on-failure', 'always', 'unless-stopped'};
  final policy = spec.restartPolicy.trim();
  if (policy.isNotEmpty && policies.contains(policy)) {
    parts.addAll(['--restart', policy]);
  }

  final quotedImage = _quote(image);
  if (quotedImage == null) {
    return DockerRunPlan.bad(DockerRunProblem.unsafeValue, image);
  }
  parts.add(quotedImage);

  final extra = spec.extraArgs.trim();
  if (extra.isNotEmpty) {
    // Refused for the same reason as any other value: a newline here would end
    // the command and start another one.
    if (extra.contains('\n') || extra.contains('\r')) {
      return DockerRunPlan.bad(DockerRunProblem.unsafeValue, extra);
    }
    parts.add(extra);
  }

  return DockerRunPlan.ok(parts.join(' '));
}

/// [value] quoted as one shell argument, or null when it cannot be.
///
/// Null for a newline or a NUL: a POSIX shell cannot put either inside single
/// quotes, and there is no safe way to pass one through this path. Refusing is
/// the honest answer — silently dropping the character would run a different
/// command from the one the user described.
String? _quote(String value) {
  if (value.contains('\n') || value.contains('\r') || value.contains('\x00')) {
    return null;
  }
  return "'${value.replaceAll("'", r"'\''")}'";
}

/// Whether [value] looks like a `a:b` pair — a port mapping or a mount.
///
/// Only the shape is checked: this app cannot know which ports a host has free
/// or which directories exist, and refusing a valid pair would be worse than
/// passing it on and letting `docker run` answer. What is checked is the colon,
/// because a port mapping without one is a typo the user would rather hear about
/// now than read as a docker error later.
bool _isPair(String value) {
  final colon = value.indexOf(':');
  return colon > 0 && colon < value.length - 1;
}
