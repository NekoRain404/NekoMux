import 'package:flutter_test/flutter_test.dart';
import 'package:neko_mux/models/file_item.dart';
import 'package:neko_mux/services/sftp_tree.dart';

/// A tree that answers listings from a map and records every removal.
class _FakeTree implements SftpTreeOps {
  _FakeTree(this.children, {this.failing = const {}});

  /// Directory path → its entries. A path absent from the map has no children.
  final Map<String, List<FileItem>> children;

  /// Paths whose removal throws, to exercise a walk that cannot finish.
  final Set<String> failing;

  final List<String> removed = [];

  @override
  Future<List<FileItem>> listDirectory(String path) async {
    final entries = children[path];
    if (entries == null) throw StateError('not a directory: $path');
    return entries;
  }

  @override
  Future<void> deleteFile(String path) async {
    if (failing.contains(path)) throw StateError('permission denied: $path');
    removed.add(path);
  }
}

FileItem dir(String path) => FileItem(
  name: path.split('/').last,
  path: path,
  isDirectory: true,
  modifiedDate: DateTime(2026),
);

FileItem file(String path) => FileItem(
  name: path.split('/').last,
  path: path,
  size: 10,
  modifiedDate: DateTime(2026),
);

void main() {
  test('a directory goes only after everything inside it', () async {
    // The ordering *is* the capability: `deleteFile` removes a file or an EMPTY
    // directory, so a walk that removed the directory first would fail on the
    // first one with contents — which is exactly why deleting a folder could
    // not work before.
    final ops = _FakeTree({
      '/var/www': [dir('/var/www/html'), file('/var/www/index.html')],
      '/var/www/html': [file('/var/www/html/a.html')],
    });

    final result = await deleteTree(ops, '/var/www', isDirectory: true);

    expect(result.complete, isTrue);
    expect(result.removed, 4);
    expect(ops.removed, [
      '/var/www/html/a.html',
      '/var/www/html',
      '/var/www/index.html',
      '/var/www',
    ]);
    expect(
      ops.removed.last,
      '/var/www',
      reason: 'the directory the user tapped goes last',
    );
  });

  test('a single file is removed without a listing', () async {
    // No listing at all: a file has no children, and asking the server to list
    // one is a round trip whose answer can only be an error.
    final ops = _FakeTree(const {});

    final result = await deleteTree(ops, '/etc/hosts', isDirectory: false);

    expect(result.complete, isTrue);
    expect(result.removed, 1);
    expect(ops.removed, ['/etc/hosts']);
  });

  test('an empty directory is still removed', () async {
    final ops = _FakeTree({'/tmp/empty': const []});

    final result = await deleteTree(ops, '/tmp/empty', isDirectory: true);

    expect(result.complete, isTrue);
    expect(ops.removed, ['/tmp/empty']);
  });

  test('a failure names the path it stopped at, and keeps what it removed',
      () async {
    final ops = _FakeTree(
      {
        '/data': [file('/data/keep.log'), file('/data/locked.log')],
      },
      failing: {'/data/locked.log'},
    );

    final result = await deleteTree(ops, '/data', isDirectory: true);

    expect(result.complete, isFalse);
    expect(result.failedPath, '/data/locked.log');
    expect(result.removed, 1, reason: 'what was already deleted stays deleted');
    expect(ops.removed, ['/data/keep.log']);
  });

  test('a failing subdirectory reports the subdirectory, not the root',
      () async {
    // The distinction matters to the user: "permission denied on
    // /var/www/private" is actionable, "/var/www failed" is not.
    final ops = _FakeTree(
      {
        '/var/www': [dir('/var/www/private')],
        '/var/www/private': [file('/var/www/private/key.pem')],
      },
      failing: {'/var/www/private/key.pem'},
    );

    final result = await deleteTree(ops, '/var/www', isDirectory: true);

    expect(result.failedPath, '/var/www/private/key.pem');
    expect(ops.removed, isEmpty);
  });

  test('the entry cap stops the walk and says so', () async {
    // A cap that reports where it stopped is honest about what it did; a walk
    // that deleted "as much as fits" without saying so is not.
    final many = [for (var i = 0; i < 10; i++) file('/bulk/f$i')];
    final ops = _FakeTree({'/bulk': many});

    final result = await deleteTree(
      ops,
      '/bulk',
      isDirectory: true,
      maxEntries: 3,
    );

    expect(result.complete, isFalse);
    expect(result.removed, 3);
    expect(ops.removed, hasLength(3));
    expect(
      ops.removed.contains('/bulk'),
      isFalse,
      reason: 'the directory itself must not go while entries remain',
    );
  });
}
