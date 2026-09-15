import 'package:flutter_test/flutter_test.dart';
import 'package:neko_mux/models/host.dart';
import 'package:neko_mux/pages/hosts/host_list_model.dart';

/// Hosts that differ only in what each test cares about.
Host _host(
  String id, {
  String? alias,
  String? group,
  String address = '10.0.0.1',
  String? username,
  HostStatus status = HostStatus.offline,
}) {
  final host = Host(
    id: id,
    alias: alias ?? id,
    ipAddress: address,
    credentialId: 'cred-$id',
    groupName: group,
  );
  host.status = status;
  host.credentialUsername = username;
  return host;
}

void main() {
  group('filterHosts', () {
    final hosts = [
      _host('a', alias: 'prod-web', address: '10.0.0.1', username: 'deploy'),
      _host('b', alias: 'staging-db', address: '10.0.0.2', username: 'root'),
      _host('c', alias: 'backup', address: '192.168.1.9', username: 'admin'),
    ];

    test('an empty query matches everything', () {
      expect(filterHosts(hosts, '').length, 3);
      expect(filterHosts(hosts, '   ').length, 3);
    });

    test('matches on alias, address and credential username', () {
      expect(filterHosts(hosts, 'prod').single.id, 'a');
      expect(filterHosts(hosts, '10.0.0.2').single.id, 'b');
      expect(filterHosts(hosts, 'admin').single.id, 'c');
      // The address is searched as typed, not as displayed — `displayAddress`
    });

    test('is case-insensitive and ignores surrounding whitespace', () {
      expect(filterHosts(hosts, '  PROD  ').single.id, 'a');
      expect(filterHosts(hosts, 'Staging').single.id, 'b');
    });

    test('a host with no credential username is not matched by null', () {
      // `credentialUsername` is null until the host list has been enriched, and
      // a query must not crash or match by accident on that path.
      final unresolved = [_host('d', alias: 'lonely')];
      expect(filterHosts(unresolved, 'lonely').single.id, 'd');
      expect(filterHosts(unresolved, 'null'), isEmpty);
    });

    test('no match returns empty, not everything', () {
      expect(filterHosts(hosts, 'nothing-matches-this'), isEmpty);
    });
  });

  group('shouldOfferSearch', () {
    test('stays out of the way while the list is short', () {
      expect(shouldOfferSearch(hostCount: 0, query: ''), isFalse);
      expect(shouldOfferSearch(hostCount: 3, query: ''), isFalse);
    });

    test('appears once the list is long enough to need it', () {
      expect(shouldOfferSearch(hostCount: 20, query: ''), isTrue);
    });

    test('stays visible while a query is active, however short the list', () {
      // Otherwise a query that filters down to one host would remove the very
      // field showing what is being filtered, and the user could not clear it.
      expect(shouldOfferSearch(hostCount: 1, query: 'prod'), isTrue);
      expect(shouldOfferSearch(hostCount: 0, query: 'prod'), isTrue);
    });
  });

  group('buildHostSections', () {
    test('splits by status in a fixed order', () {
      final sections = buildHostSections([
        _host('off', status: HostStatus.offline),
        _host('on', status: HostStatus.online),
        _host('unv', status: HostStatus.unverified),
      ], '');

      expect(sections.map((s) => s.status).toList(), [
        HostStatus.online,
        HostStatus.unverified,
        HostStatus.offline,
      ]);
      expect(sections.map((s) => s.count).toList(), [1, 1, 1]);
    });

    test(
      'groups inside a section, with ungrouped hosts as a null-named group',
      () {
        final sections = buildHostSections([
          _host('a', group: 'prod'),
          _host('b', group: 'prod'),
          _host('c'),
        ], '');

        final offline = sections.firstWhere(
          (s) => s.status == HostStatus.offline,
        );
        final byName = {for (final g in offline.groups) g.name: g.hosts.length};
        expect(byName['prod'], 2);
        expect(byName[null], 1);
      },
    );

    test('a filtered-out host cannot appear in any section', () {
      // The overview counts what is on screen; if a section could still hold a
      // host the filter rejected, the totals and the rows would disagree.
      final sections = buildHostSections([
        _host('a', alias: 'keep-me'),
        _host('b', alias: 'drop-me'),
      ], 'keep-me');

      final total = sections.fold<int>(0, (sum, s) => sum + s.count);
      expect(total, 1);
    });

    test('every status is present even when empty', () {
      // The caller renders headers from the same list, so an absent section
      // would be an absent header rather than a zero.
      final sections = buildHostSections([], '');
      expect(sections.length, HostStatus.values.length);
      expect(sections.every((s) => s.count == 0), isTrue);
    });
  });

  group('shouldShowGroupHeaders', () {
    test('nothing to distinguish when every host is ungrouped', () {
      final sections = buildHostSections([_host('a'), _host('b')], '');
      expect(shouldShowGroupHeaders(sections), isFalse);
    });

    test('only one group in use is still nothing to distinguish', () {
      final sections = buildHostSections([
        _host('a', group: 'prod'),
        _host('b', group: 'prod'),
      ], '');
      expect(shouldShowGroupHeaders(sections), isFalse);
    });

    test('a second group makes the headers worth showing', () {
      final sections = buildHostSections([
        _host('a', group: 'prod'),
        _host('b', group: 'staging'),
      ], '');
      expect(shouldShowGroupHeaders(sections), isTrue);
    });

    test('an empty group does not count as a group in use', () {
      // A filtered-out host still produces a group object; counting it would
      // show headers for groups with nothing under them.
      final sections = buildHostSections([
        _host('a', alias: 'match', group: 'prod'),
        _host('b', alias: 'other', group: 'staging'),
      ], 'match');
      expect(shouldShowGroupHeaders(sections), isFalse);
    });
  });

  group('existingGroupNames', () {
    test('lists each group once, in a stable order', () {
      final names = existingGroupNames([
        _host('a', group: 'prod'),
        _host('b', group: 'staging'),
        _host('c', group: 'prod'),
      ]);
      expect(names.toSet(), {'prod', 'staging'});
      expect(names.length, 2);
    });

    test('ignores ungrouped hosts and blank group names', () {
      final names = existingGroupNames([
        _host('a'),
        _host('b', group: '   '),
        _host('c', group: 'prod'),
      ]);
      expect(names, ['prod']);
    });

    test('trims, so a stray space cannot create a second group', () {
      // "prod " and "prod" are the same intent; offering them as two chips is
      // how a user ends up splitting one group in two.
      final names = existingGroupNames([
        _host('a', group: ' prod '),
        _host('b', group: 'prod'),
      ]);
      expect(names, ['prod']);
    });
  });
}
