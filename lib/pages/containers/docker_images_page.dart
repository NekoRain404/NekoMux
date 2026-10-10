// The image list, and the two things a phone needs to do to it: fetch one, and
// reclaim the space the unused ones hold.
//
// This is the other half of the container module. A container can be created,
// inspected and removed from the app; the images they are built from were
// invisible, and on a host running low on space they are usually the answer —
// the machine this was built against held 78 dangling images at roughly 360 MB
// each.

import 'package:flutter/material.dart';

import '../../core/i18n/strings.dart';
import '../../core/theme/app_fonts.dart';
import '../../services/ssh_service.dart';
import '../../widgets/app_ui.dart';
import 'docker_images.dart';

/// Shows the images on a host, and lets the unused ones go.
///
/// The page holds the session rather than a loader: unlike the detail and scan
/// views, which read once, this one runs several different commands from
/// several places in the UI, and threading a callback for each would be more
/// indirection than the thing it wraps.
class DockerImagesPage extends StatefulWidget {
  /// The session to run commands over.
  final SshConnection? ssh;

  const DockerImagesPage({super.key, required this.ssh});

  @override
  State<DockerImagesPage> createState() => _DockerImagesPageState();
}

class _DockerImagesPageState extends State<DockerImagesPage> {
  List<DockerImage> _images = const [];
  bool _loading = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// Whether the session is usable right now.
  bool get _connected =>
      widget.ssh != null &&
      widget.ssh!.state == SshConnectionState.connected;

  Future<void> _load() async {
    if (!_connected) {
      setState(() {
        _loading = false;
        _error = t('ssh_not_connected');
      });
      return;
    }

    setState(() => _loading = true);
    try {
      final result = await widget.ssh!.runCommand(dockerImagesCommand);
      if (!mounted) return;
      if (!result.ok) {
        setState(() {
          _loading = false;
          _error = result.combined.trim().isEmpty
              ? 'exit status ${result.exitCode ?? 'unknown'}'
              : result.combined.trim();
        });
        return;
      }
      setState(() {
        _images = parseDockerImages(result.stdout);
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '${t('error')}: $e';
        });
      }
    }
  }

  /// Runs one command and reports what the daemon said about it.
  ///
  /// Every action on this page ends the same way: run it, read the exit status,
  /// show the daemon's own words on failure, and reload only when something
  /// actually changed. Written once because the alternative is three copies of
  /// the rule that a non-zero status is the only failure signal.
  Future<void> _run(String? command, String successMessage) async {
    if (command == null || !_connected || _busy) return;

    setState(() => _busy = true);
    try {
      final result = await widget.ssh!.runCommand(command);
      if (!mounted) return;
      if (!result.ok) {
        _toast(
          '${t('image_action_failed')}: '
          '${result.combined.trim().isEmpty ? result.exitCode : result.combined.trim()}',
          isError: true,
        );
        return;
      }
      _toast(successMessage);
      await _load();
    } catch (e) {
      if (mounted) {
        _toast('${t('image_action_failed')}: $e', isError: true);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _toast(String message, {bool isError = false}) {
    if (!mounted) return;
    final cs = Theme.of(context).colorScheme;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        backgroundColor: isError ? cs.error : null,
      ),
    );
  }

  /// Asks for an image reference and pulls it.
  Future<void> _promptPull() async {
    final controller = TextEditingController();
    final reference = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Theme.of(ctx).colorScheme.surface,
        title: Text(t('image_pull')),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: AppFonts.monoText(
            color: Theme.of(ctx).colorScheme.onSurface,
            fontSize: 14,
          ),
          decoration: InputDecoration(hintText: t('image_pull_hint')),
          onSubmitted: (value) => Navigator.pop(ctx, value.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(t('cancel')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: Text(t('confirm')),
          ),
        ],
      ),
    );
    controller.dispose();

    if (reference == null || reference.isEmpty) return;
    await _run(dockerPullCommand(reference), t('image_pulled'));
  }

  /// Confirms, then reclaims the dangling images.
  ///
  /// The count comes from the listing already on screen, so the dialog cannot
  /// promise a number the page is not showing. That matters more than usual
  /// here: a prune cannot be undone, and `docker image prune` has no dry run to
  /// check against.
  Future<void> _confirmPrune() async {
    final dangling = danglingImages(_images);
    if (dangling.isEmpty) {
      _toast(t('image_no_dangling'));
      return;
    }

    final confirmed = await showAppConfirmDialog(
      context,
      title: t('image_prune'),
      message: t('image_prune_confirm').replaceAll('{0}', '${dangling.length}'),
      cancelLabel: t('cancel'),
      confirmLabel: t('image_prune'),
      destructive: true,
    );
    if (!confirmed) return;

    await _run(dockerImagePruneCommand, t('image_pruned'));
  }

  /// Asks, then removes one image.
  Future<void> _confirmRemove(DockerImage image) async {
    final confirmed = await showAppConfirmDialog(
      context,
      title: t('image_remove'),
      message: t('image_remove_confirm').replaceAll('{0}', image.displayName),
      cancelLabel: t('cancel'),
      confirmLabel: t('delete'),
      destructive: true,
    );
    if (!confirmed) return;

    await _run(
      dockerImageRemoveCommand(image.id),
      t('image_removed'),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final dangling = danglingImages(_images);

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        backgroundColor: cs.surface,
        title: Text(
          t('docker_images'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            icon: Icon(Icons.download_outlined, size: 21, color: cs.secondary),
            tooltip: t('image_pull'),
            onPressed: _loading || _busy ? null : _promptPull,
          ),
          IconButton(
            icon: Icon(Icons.cleaning_services_outlined, size: 21, color: cs.error),
            tooltip: t('image_prune'),
            onPressed: _loading || _busy ? null : _confirmPrune,
          ),
          IconButton(
            icon: Icon(
              Icons.refresh,
              size: 21,
              color: cs.onSurface.withValues(alpha: 0.6),
            ),
            tooltip: t('refresh'),
            onPressed: _loading || _busy ? null : _load,
          ),
        ],
      ),
      body: _body(cs, dangling),
    );
  }

  Widget _body(ColorScheme cs, List<DockerImage> dangling) {
    if (_loading && _images.isEmpty) {
      return Center(child: CircularProgressIndicator(color: cs.primary));
    }

    if (_error != null && _images.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline, color: cs.error, size: 44),
              const SizedBox(height: 14),
              SelectableText(
                _error!,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: cs.onSurface.withValues(alpha: 0.7),
                  fontSize: 13,
                ),
              ),
              const SizedBox(height: 18),
              OutlinedButton.icon(
                onPressed: _load,
                icon: const Icon(Icons.refresh, size: 18),
                label: Text(t('retry')),
                style: OutlinedButton.styleFrom(
                  foregroundColor: cs.primary,
                  side: BorderSide(color: cs.primary),
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (_images.isEmpty) {
      return Center(
        child: Text(
          t('image_none'),
          style: TextStyle(
            color: cs.onSurface.withValues(alpha: 0.6),
            fontSize: 14,
          ),
        ),
      );
    }

    return RefreshIndicator(
      color: cs.primary,
      backgroundColor: cs.surface,
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          if (dangling.isNotEmpty) _DanglingNotice(count: dangling.length),
          for (final image in _images)
            _ImageRow(
              image: image,
              busy: _busy,
              onTap: () => _confirmRemove(image),
            ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

/// Says how many images a prune would reclaim, above the list they are in.
class _DanglingNotice extends StatelessWidget {
  final int count;

  const _DanglingNotice({required this.count});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cs.error.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: cs.error.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(Icons.cleaning_services_outlined, color: cs.error, size: 17),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              t('image_dangling_count').replaceAll('{0}', '$count'),
              style: TextStyle(color: cs.error, fontSize: 12.5),
            ),
          ),
        ],
      ),
    );
  }
}

/// One image: its name, size and age, with dangling ones marked.
class _ImageRow extends StatelessWidget {
  final DockerImage image;
  final bool busy;
  final VoidCallback onTap;

  const _ImageRow({
    required this.image,
    required this.busy,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AppCard(
      margin: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      onTap: busy ? null : onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  image.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppFonts.monoText(
                    // A dangling image has no name, so the id stands in; it is
                    // dimmed because it is not a name the user chose.
                    color: image.isDangling
                        ? cs.onSurface.withValues(alpha: 0.55)
                        : cs.onSurface,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (image.isDangling) ...[
                const SizedBox(width: 6),
                Text(
                  t('image_dangling'),
                  style: TextStyle(color: cs.error, fontSize: 10),
                ),
              ],
              const SizedBox(width: 8),
              Text(
                image.size,
                style: AppFonts.monoText(color: cs.secondary, fontSize: 12),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            image.createdSince,
            style: TextStyle(
              color: cs.onSurface.withValues(alpha: 0.45),
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }
}
