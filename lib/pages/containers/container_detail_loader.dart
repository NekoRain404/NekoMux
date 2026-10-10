// Reading one container's detail over an SSH session, and the outcome type the
// view renders.
//
// Split out from both neighbours on purpose. [ContainerDetailOutcome] cannot
// live in the view, because the page would then be the only thing that can
// produce one and the loader would have to import a widget file to return a
// value. Nor can it live in `docker_detail.dart`, which is pure parsing with no
// connection of any kind and is tested that way — handing it an `SshConnection`
// to hold would cost it exactly the property that makes it testable.
//
// So this file is the seam: it knows a session and a command, and it knows
// nothing about how any of it is drawn.

import 'package:flutter/foundation.dart';

import '../../core/i18n/strings.dart';
import '../../services/ssh_service.dart';
import 'docker_detail.dart';
import 'remote_action_outcome.dart';

/// Fetches one container's detail; owned by the page holding the connection.
typedef ContainerDetailLoader = Future<ContainerDetailOutcome> Function();

/// Either the detail or the reason it could not be read.
///
/// A failure is carried as text rather than thrown, matching `showLogViewer`:
/// the caller turns a missing connection and a refused `docker inspect` into a
/// sentence in the user's language, and the view renders whatever it is handed
/// without needing words for an exception.
@immutable
class ContainerDetailOutcome {
  /// The container, when the daemon answered.
  final ContainerDetail? detail;

  /// What went wrong, when it did.
  final String? failure;

  const ContainerDetailOutcome.loaded(ContainerDetail this.detail)
    : failure = null;

  const ContainerDetailOutcome.failed(String this.failure) : detail = null;

  /// Whether there is a container to render.
  bool get isLoaded => detail != null;
}

/// Reads [container]'s full configuration over [ssh].
///
/// [ssh] is nullable because a caller reads the current session at call time
/// rather than capturing one: a refresh after a reconnect has to use the new
/// connection, and a null simply means there is none to use yet.
///
/// Every failure comes back as text, including the ones that are not the
/// daemon's fault — a dropped session is reported in the user's language rather
/// than as whatever the socket threw.
///
/// A successful command that yielded no readable row is a failure too. It is
/// the one case that could be mistaken for an empty result, and an empty detail
/// view is indistinguishable from a container with nothing configured — which
/// is a real state and must not be what a parse failure looks like.
Future<ContainerDetailOutcome> loadContainerDetail(
  SshConnection? ssh,
  String container,
) async {
  if (ssh == null || ssh.state != SshConnectionState.connected) {
    return ContainerDetailOutcome.failed(t('ssh_not_connected'));
  }

  try {
    final result = await ssh.runCommand(dockerDetailCommand(container));
    if (!result.ok) {
      // The daemon's own words: `No such container`, `permission denied while
      // trying to connect to the Docker daemon socket`. Same rule as every
      // other command in this module — the exit status decides, the output
      // only explains.
      return ContainerDetailOutcome.failed(remoteFailureText(result));
    }

    final details = parseContainerDetail(result.combined);
    if (details.isEmpty) {
      return ContainerDetailOutcome.failed(t('container_detail_failed'));
    }
    return ContainerDetailOutcome.loaded(details.first);
  } catch (e) {
    return ContainerDetailOutcome.failed('${t('error')}: $e');
  }
}
