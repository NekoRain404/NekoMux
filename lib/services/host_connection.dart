import 'package:sqflite/sqflite.dart';

import '../models/credential.dart';
import '../models/host.dart';
import 'host_key_trust.dart';
import 'known_hosts_store.dart';
import 'ssh_service.dart';

/// The bastion a host is reached through, with the credential it authenticates
/// with.
class JumpRoute {
  final Host host;
  final Credential credential;

  const JumpRoute({required this.host, required this.credential});
}

/// Resolves [host]'s bastion from the lists the pages already hold, or null when
/// it is dialled directly.
///
/// Null is also the answer for every way this can fail to resolve — no jump host
/// set, an id that names a host the user has since deleted, or a bastion with no
/// usable credential. Those are the same case from the connection's point of
/// view: there is no route to go through, so it dials directly and the failure,
/// if any, is about the target rather than about a bastion the user cannot see.
///
/// A host that jumps to ITSELF is refused for the same reason: it is a loop the
/// user did not mean to make, and following it would mean dialling the target
/// through the target.
JumpRoute? jumpRouteFor(
  Host host, {
  required List<Host> hosts,
  required List<Credential> credentials,
}) {
  final jumpId = host.jumpHostId;
  if (jumpId == null || jumpId == host.id) return null;

  final bastion = hosts.where((h) => h.id == jumpId).firstOrNull;
  if (bastion == null) return null;

  final credential = credentials
      .where((c) => c.id == bastion.credentialId)
      .firstOrNull;
  if (credential == null) return null;

  return JumpRoute(host: bastion, credential: credential);
}

/// Builds a connection to [host], wired to go through [jump] when there is one.
///
/// One place decides how a connection is put together, so the terminal, the
/// console, the file manager, the transfer queue, the batch runner and the
/// tunnel service cannot each grow their own idea of it. The two host-key
/// verifiers are built here as well, which is what keeps the rule that both hops
/// are verified — a tunnel through a bastion that checked only one of the two
/// keys would be confirming the wrong machine half the time.
///
/// [onPrompt] answers the key question for whichever hop is being verified; the
/// caller passes its own dialog. When [refuseUntrusted] is set, neither hop asks
/// and neither accepts — the background paths (the reachability probe, the batch
/// runner) use that, because a modal the user never asked for is one they learn
/// to dismiss on reflex.
SshConnection buildHostConnection({
  required Host host,
  required Credential credential,
  required Database db,
  required Duration connectTimeout,
  JumpRoute? jump,
  required Future<bool> Function(String fingerprint, HostKeyVerdict verdict)
  onPrompt,
  bool refuseUntrusted = false,
  /// Set from inside the verifier when a key was presented and refused, so a
  /// caller can tell "the user said no to this key" from "the credentials were
  /// wrong" — dartssh2 reports both as an authentication abort.
  void Function()? onTrustRefused,
}) {
  Future<bool> Function(String, String) verifierFor(Host target) {
    return (type, fingerprint) => buildHostKeyVerifier(
      db: db,
      address: target.ipAddress,
      port: target.port,
      onPrompt: refuseUntrusted
          ? (_, _) async {
              onTrustRefused?.call();
              return false;
            }
          : (_, verdict) => onPrompt(fingerprint, verdict),
    )(fingerprint);
  }

  return SshConnection(
    host: host,
    credential: credential,
    connectTimeout: connectTimeout,
    onHostKeyVerifyTyped: verifierFor(host),
    jumpHost: jump?.host,
    jumpCredential: jump?.credential,
    onJumpHostKeyVerify: jump == null ? null : verifierFor(jump.host),
  );
}
