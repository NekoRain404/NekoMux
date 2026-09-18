import 'package:flutter_test/flutter_test.dart';
import 'package:neko_mux/models/credential.dart';
import 'package:neko_mux/models/host.dart';
import 'package:neko_mux/services/host_connection.dart';

/// Resolving a host's bastion, which is where every failure mode of the jump
/// feature lands.
///
/// A route that resolves to the wrong thing is not a visible error: the app
/// dials *something*, and the user sees a connection that fails, or worse, one
/// that succeeds against a machine they did not mean. So each way the resolution
/// can go wrong is pinned here, and each of them answers "no route" — which the
/// connection treats as a direct dial rather than as a jump to nowhere.
Host hostOf(String id, {String? jumpsTo}) => Host(
  id: id,
  alias: id,
  ipAddress: '10.0.0.1',
  credentialId: 'cred-$id',
  jumpHostId: jumpsTo,
);

Credential credOf(String id) => Credential(
  id: id,
  name: id,
  authType: 0,
  username: 'root',
  secretData: 'x',
);

void main() {
  test('a host with a bastion resolves to that host and its credential', () {
    final hosts = [hostOf('target', jumpsTo: 'bastion'), hostOf('bastion')];
    final credentials = [credOf('cred-bastion'), credOf('cred-target')];

    final route = jumpRouteFor(
      hosts.first,
      hosts: hosts,
      credentials: credentials,
    );

    expect(route, isNotNull);
    expect(route!.host.id, 'bastion');
    expect(
      route.credential.id,
      'cred-bastion',
      reason: 'the bastion authenticates with its OWN credential, not the '
          'target’s — they are different machines with different logins',
    );
  });

  test('a host with no bastion resolves to nothing', () {
    final hosts = [hostOf('plain')];
    expect(
      jumpRouteFor(hosts.first, hosts: hosts, credentials: [credOf('cred-plain')]),
      isNull,
    );
  });

  test('a bastion that no longer exists resolves to nothing', () {
    // The user deleted the bastion and kept the hosts behind it. Dialling
    // directly is the only honest answer: the alternative is a connection that
    // fails with an error about a machine that is not in the list any more.
    final target = hostOf('target', jumpsTo: 'deleted');
    final route = jumpRouteFor(
      target,
      hosts: [target],
      credentials: [credOf('cred-target')],
    );
    expect(route, isNull);
  });

  test('a bastion with no usable credential resolves to nothing', () {
    final hosts = [hostOf('target', jumpsTo: 'bastion'), hostOf('bastion')];
    final route = jumpRouteFor(
      hosts.first,
      hosts: hosts,
      credentials: const [], // the bastion's credential was deleted
    );
    expect(route, isNull);
  });

  test('a host that jumps to itself resolves to nothing', () {
    // A loop the user did not mean to make. Following it would mean dialling the
    // target through the target, which is either a hang or an error about a
    // host being unreachable from itself.
    final self = hostOf('self', jumpsTo: 'self');
    final route = jumpRouteFor(
      self,
      hosts: [self],
      credentials: [credOf('cred-self')],
    );
    expect(route, isNull);
  });

  test('only one hop is followed', () {
    // A bastion that has a bastion of its own is not a chain this app dials: the
    // route points at the first bastion and stops. Stated as a test because the
    // alternative — silently following the chain — would make a two-hop setup
    // work by accident on some hosts and fail on others.
    final hosts = [
      hostOf('target', jumpsTo: 'bastion'),
      hostOf('bastion', jumpsTo: 'outer'),
      hostOf('outer'),
    ];
    final route = jumpRouteFor(
      hosts.first,
      hosts: hosts,
      credentials: [credOf('cred-bastion'), credOf('cred-outer')],
    );

    expect(route, isNotNull);
    expect(
      route!.host.id,
      'bastion',
      reason: 'the route is one hop, and it is the one the target named',
    );
  });
}
