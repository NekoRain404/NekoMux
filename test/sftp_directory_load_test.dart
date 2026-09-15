import 'package:flutter_test/flutter_test.dart';
import 'package:neko_mux/pages/sftp/directory_load_state.dart';
import 'package:neko_mux/pages/sftp/file_selection.dart';

void main() {
  group('DirectoryLoadState', () {
    test(
      'a committed listing becomes both the shown and the requested path',
      () {
        final state = DirectoryLoadState('/');
        final request = state.begin('/var/log');

        expect(state.requestedPath, '/var/log');
        expect(state.shownPath, '/', reason: 'nothing is listed from it yet');
        expect(state.isLoading, isTrue);

        expect(state.commitLoaded(request), isTrue);
        expect(state.shownPath, '/var/log');
        expect(state.requestedPath, '/var/log');
        expect(state.isLoading, isFalse);
      },
    );

    test('the older of two overlapping loads cannot overwrite the newer one', () {
      // Reproduces the desync: the breadcrumb is tapped while the first listing
      // is still in flight, so two loads are outstanding at once.
      final state = DirectoryLoadState('/');
      final slow = state.begin('/var/log');
      final fast = state.begin('/home/user');

      expect(state.commitLoaded(fast), isTrue);
      expect(state.shownPath, '/home/user');

      expect(
        state.commitLoaded(slow),
        isFalse,
        reason: 'the response that lost the race must be dropped whole',
      );
      expect(state.shownPath, '/home/user');
      expect(state.requestedPath, '/home/user');
      expect(
        state.isLoading,
        isFalse,
        reason: 'the newer load already finished',
      );
    });

    test('a stale response does not clear the spinner of a live load', () {
      final state = DirectoryLoadState('/');
      final stale = state.begin('/var/log');
      state.begin('/home/user');

      // Both the success and the failure path of the stale response.
      expect(state.isCurrent(stale), isFalse);
      expect(state.commitLoaded(stale), isFalse);
      expect(state.commitFailed(stale), isFalse);
      expect(state.isLoading, isTrue);
      expect(state.shownPath, '/');
    });

    test('a failed listing rolls the requested path back to what is listed', () {
      // Reproduces the swallowed error: /etc is on screen, the user browses into
      // a directory they cannot read.
      final state = DirectoryLoadState('/');
      state.commitLoaded(state.begin('/etc'));

      final request = state.begin('/root');
      expect(state.requestedPath, '/root');

      expect(state.commitFailed(request), isTrue);
      expect(
        state.requestedPath,
        '/etc',
        reason:
            'the path bar must not name a directory whose contents never '
            'arrived, since create/rename build their target from it',
      );
      expect(state.shownPath, '/etc');
      expect(state.isLoading, isFalse);
    });

    test('a refresh failure keeps the directory that is still displayed', () {
      final state = DirectoryLoadState('/');
      state.commitLoaded(state.begin('/etc'));

      expect(state.commitFailed(state.begin('/etc')), isTrue);
      expect(state.requestedPath, '/etc');
      expect(state.shownPath, '/etc');
    });

    test('a failure on the very first load stays on the opening directory', () {
      final state = DirectoryLoadState('/');

      expect(state.commitFailed(state.begin('/')), isTrue);
      expect(state.requestedPath, '/');
      expect(state.shownPath, '/');
      expect(state.isLoading, isFalse);
    });
  });

  group('FileSelection', () {
    test('starting a selection activates the mode with that path ticked', () {
      final selection = FileSelection();
      selection.begin('/etc/passwd');

      expect(selection.isActive, isTrue);
      expect(selection.count, 1);
      expect(selection.contains('/etc/passwd'), isTrue);
    });

    test('toggling adds and removes', () {
      final selection = FileSelection()..begin('/a');
      selection.toggle('/b');
      expect(selection.paths, {'/a', '/b'});

      selection.toggle('/a');
      expect(selection.paths, {'/b'});
      expect(selection.isActive, isTrue);
    });

    test('unticking the last entry leaves the mode', () {
      final selection = FileSelection()..begin('/a');
      selection.toggle('/a');

      expect(
        selection.isActive,
        isFalse,
        reason: 'a bar offering to act on nothing must not be reachable',
      );
      expect(selection.paths, isEmpty);
    });

    test('paths are reported in the order they were selected', () {
      final selection = FileSelection()..begin('/c');
      selection.toggle('/a');
      selection.toggle('/b');

      expect(selection.paths.toList(), ['/c', '/a', '/b']);
    });

    test('clearing drops everything and leaves the mode', () {
      // Reproduces the batch-delete hazard: a path selected in one directory
      // must not survive navigation into another, or the bar would offer to
      // delete a file the user can no longer see.
      final selection = FileSelection()..begin('/var/log/syslog');
      selection.toggle('/var/log/auth.log');

      selection.clear();

      expect(selection.isActive, isFalse);
      expect(selection.count, 0);
      expect(selection.contains('/var/log/syslog'), isFalse);
      expect(selection.paths, isEmpty);
    });

    test('the reported set cannot be mutated from outside', () {
      final selection = FileSelection()..begin('/a');

      expect(
        () => selection.paths.add('/b'),
        throwsUnsupportedError,
        reason: 'a caller must go through toggle/clear to change the selection',
      );
      expect(selection.paths, {'/a'});
    });
  });
}
