// The image list, and the commands that change it.
//
// The container module could create, inspect, start and remove containers but
// never showed the images they come from — which is where the space goes. One
// machine this was built against held 78 dangling images at roughly 360 MB
// each, and nothing in the app could see them, let alone reclaim them.

import '../../services/shell_quote.dart';

/// Lists every image, dangling ones included.
///
/// `-a` is not a preference, it is the difference between a complete list and a
/// misleading one. Docker 29's default `docker images` **hides dangling
/// images** — on the machine this was written against it printed 41 rows where
/// `-a` printed 119, and the 78 it omitted are exactly the ones a prune
/// removes. A page listing with the default and pruning with `docker image
/// prune` would delete images the user was never shown.
///
/// Pipe-delimited for the same reason the other listings are: the columns are
/// aligned by the daemon and an image tag cannot contain a pipe.
const String dockerImagesCommand =
    "docker images -a --format "
    "'{{.Repository}}|{{.Tag}}|{{.ID}}|{{.Size}}|{{.CreatedSince}}'";

/// Removes every dangling image.
///
/// `-f` is mandatory rather than convenient. Without it the daemon prompts for
/// confirmation, and over SSH that prompt is not a prompt: the command waits on
/// a stdin that will never arrive and the session hangs until it times out —
/// the same failure `docker stats` has without `--no-stream`. So the
/// confirmation has to happen in the app, and it does: the page counts the
/// dangling images from the listing the user is already looking at and names
/// that number in the dialog before this runs.
///
/// `--dry-run` would have been the better shape for this, and it does not
/// exist.
const String dockerImagePruneCommand = 'docker image prune -f';

/// Removes one image.
///
/// Null when [id] holds a character that cannot be quoted, which the caller
/// must not paper over by passing it raw.
///
/// The id comes from `docker images` and is a hex string, but it is quoted
/// anyway: this is the one path where a value the daemon printed becomes an
/// argument, and the cost of quoting a safe value is nothing.
String? dockerImageRemoveCommand(String id) {
  final quoted = shellQuote(id);
  return quoted == null ? null : 'docker rmi $quoted';
}

/// Fetches [reference] from its registry.
///
/// [reference] is whatever the user typed — `nginx:alpine`, a registry host, a
/// digest — so unlike a container name it is genuinely untrusted and quoting it
/// is load-bearing.
String? dockerPullCommand(String reference) {
  final quoted = shellQuote(reference);
  return quoted == null ? null : 'docker pull $quoted';
}

/// One image as `docker images` reports it.
class DockerImage {
  /// Repository part of the reference, or `<none>` for a dangling image.
  final String repository;

  /// Tag, or `<none>` for a dangling image.
  final String tag;

  /// Short image id — twelve hex characters.
  final String id;

  /// Size as the daemon renders it (`362MB`). Kept as text: it is already in
  /// the form the user reads, and converting it back to bytes would introduce a
  /// rounding the daemon did not make.
  final String size;

  /// Age as the daemon renders it (`3 weeks ago`).
  final String createdSince;

  const DockerImage({
    required this.repository,
    required this.tag,
    required this.id,
    required this.size,
    required this.createdSince,
  });

  /// Whether no tag points at this image.
  ///
  /// The daemon writes `<none>` in both columns for these. They are the
  /// build leftovers nothing references, and they are what a prune reclaims.
  bool get isDangling => repository == '<none>' || tag == '<none>';

  /// What to show as the image's name.
  ///
  /// A dangling image has no name to show — `<none>:<none>` identifies nothing
  /// and appears dozens of times in a list, so the id is used instead, which is
  /// what `docker rmi` would take and what a person would search for.
  String get displayName => isDangling ? id : '$repository:$tag';
}

/// Reads `docker images -a` output.
///
/// Rows with fewer than five fields are skipped rather than guessed at, the
/// same rule the other listings follow: a half-read row would put a real
/// repository name next to a size that belongs to a different image.
List<DockerImage> parseDockerImages(String output) {
  final images = <DockerImage>[];

  for (final line in output.split('\n')) {
    if (line.trim().isEmpty) continue;
    final parts = line.split('|');
    if (parts.length < 5) continue;

    final repository = parts[0].trim();
    final id = parts[2].trim();
    // An empty repository is not a shape the daemon produces — an untagged
    // image is written `<none>` — so a row carrying one has lost a column, and
    // the fields after it cannot be trusted to line up with the sizes they sit
    // beside. Skipped for the same reason as a short row.
    if (repository.isEmpty || id.isEmpty) continue;

    images.add(
      DockerImage(
        repository: repository,
        tag: parts[1].trim(),
        id: id,
        size: parts[3].trim(),
        createdSince: parts[4].trim(),
      ),
    );
  }

  return images;
}

/// The dangling images in [images], which a prune would remove.
///
/// Derived from the listing rather than asked for separately, so the count the
/// confirmation names is the count the user can see. A second command could
/// disagree with the list on screen — the daemon moves between two calls — and
/// a dialog promising to remove a number the page is not showing is a dialog
/// about something the user cannot check.
List<DockerImage> danglingImages(List<DockerImage> images) => [
  for (final image in images)
    if (image.isDangling) image,
];

/// What `docker image prune -f` reported reclaiming.
///
/// The daemon's own words, not a total this app computed: image sizes are
/// printed in decimal units (`362MB`) and summing them here would produce a
/// number that disagrees with the one Docker prints, in a screen whose whole
/// purpose is showing how much space came back.
class PruneResult {
  /// How many images were removed, or null when the daemon did not say.
  final int? removed;

  /// The daemon's `Total reclaimed space` line, or empty when it printed none.
  final String reclaimed;

  const PruneResult({required this.removed, required this.reclaimed});

  /// Whether there was nothing to remove.
  bool get removedNothing => (removed ?? 0) == 0;
}

/// Reads `docker image prune -f` output.
///
/// The shape is:
///
///     Deleted Images:
///     deleted: sha256:ada6cc…
///     deleted: sha256:c68151…
///
///     Total reclaimed space: 27.9GB
///
/// `Deleted Images:` and the space line are absent when there was nothing to
/// do, which is a real answer and not an error — a host with no dangling
/// images prunes successfully and reclaims nothing.
PruneResult parsePruneResult(String output) {
  var removed = 0;
  var reclaimed = '';
  var sawDeleted = false;

  for (final line in output.split('\n')) {
    final text = line.trim();
    if (text.startsWith('deleted:')) {
      sawDeleted = true;
      removed++;
      continue;
    }
    // The daemon labels the line `Total reclaimed space: 27.9GB`; only the
    // value is kept, because the label is this app's to translate.
    const marker = 'Total reclaimed space:';
    if (text.startsWith(marker)) {
      reclaimed = text.substring(marker.length).trim();
    }
  }

  return PruneResult(
    removed: sawDeleted ? removed : null,
    reclaimed: reclaimed,
  );
}
