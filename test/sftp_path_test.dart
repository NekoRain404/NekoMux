import 'package:flutter_test/flutter_test.dart';
import 'package:neko_mux/pages/sftp/sftp_path.dart';

void main() {
  group('sftpExtension', () {
    test('takes the last extension of a multi-dot name', () {
      expect(sftpExtension('archive.tar.gz'), 'gz');
      expect(sftpExtension('nginx.conf.bak'), 'bak');
    });

    test('lower-cases the extension', () {
      expect(sftpExtension('IMG_0001.JPG'), 'jpg');
      expect(sftpExtension('Deploy.SH'), 'sh');
    });

    test('keeps the historical whole-name rule for a name with no dot', () {
      // The file manager has always treated the name after the last dot — or the
      // whole name when there is none — as the extension. A file called `log`
      // therefore opens in the preview, exactly as it did before this was
      // extracted; the extraction must not quietly change that.
      expect(sftpExtension('log'), 'log');
      expect(sftpExtension('Makefile'), 'makefile');
    });

    test('handles degenerate names without throwing', () {
      expect(sftpExtension(''), '');
      expect(sftpExtension('.'), '');
      expect(sftpExtension('trailing.'), '');
    });
  });

  group('isSftpTextFile', () {
    test('accepts the extensions the manager previews', () {
      for (final name in [
        'app.log', // the file type most likely to be non-UTF-8 on a CN host
        'nginx.conf',
        'php.ini',
        'deploy.sh',
        'config.yml',
        'readme.md',
      ]) {
        expect(isSftpTextFile(name), isTrue, reason: name);
      }
    });

    test('rejects everything else', () {
      for (final name in [
        'photo.png',
        'archive.tar.gz',
        'server',
        'icon.svg',
      ]) {
        expect(isSftpTextFile(name), isFalse, reason: name);
      }
    });
  });

  group('sftpChildPath', () {
    test('joins onto a normal directory', () {
      expect(sftpChildPath('/var', 'log'), '/var/log');
      expect(sftpChildPath('/home/user', 'notes.txt'), '/home/user/notes.txt');
    });

    test('does not double the separator at the root', () {
      expect(sftpChildPath('/', 'etc'), '/etc');
      expect(sftpChildPath('/var/', 'log'), '/var/log');
    });
  });

  group('sftpBaseName', () {
    test('returns the last segment', () {
      expect(sftpBaseName('/var/log/syslog'), 'syslog');
      expect(sftpBaseName('/etc'), 'etc');
    });

    test('returns something usable for the root itself', () {
      expect(sftpBaseName('/'), '');
    });
  });

  group('sftpBreadcrumbs', () {
    test('the root alone produces a single crumb', () {
      final crumbs = sftpBreadcrumbs('/');
      expect(crumbs, hasLength(1));
      expect(crumbs.single.path, '/');
    });

    test('deeper paths produce one crumb per segment', () {
      final rootLabel = sftpBreadcrumbs('/').single.label;
      final crumbs = sftpBreadcrumbs('/var/log');
      expect(crumbs.map((c) => c.label).toList(), [rootLabel, 'var', 'log']);
      expect(crumbs.map((c) => c.path).toList(), ['/', '/var', '/var/log']);
    });

    test('the root label is the localised one, without its decoration', () {
      // The path bar has never shown the house emoji stored with the label.
      expect(sftpBreadcrumbs('/').single.label, isNot(contains('🏠')));
      expect(sftpBreadcrumbs('/etc').first.label, isNot(contains('🏠')));
    });

    test('the last crumb always points at the directory being shown', () {
      for (final path in ['/', '/var', '/var/log', '/a/b/c/d/e']) {
        expect(sftpBreadcrumbs(path).last.path, path, reason: path);
      }
    });

    test('ignores empty segments from repeated or trailing slashes', () {
      expect(sftpBreadcrumbs('/var/log/').map((c) => c.path).toList(), [
        '/',
        '/var',
        '/var/log',
      ]);
      expect(sftpBreadcrumbs('/var//log').map((c) => c.path).toList(), [
        '/',
        '/var',
        '/var/log',
      ]);
    });

    test('crumbs compare by value', () {
      expect(
        sftpBreadcrumbs('/etc'),
        contains(const SftpCrumb(label: 'etc', path: '/etc')),
      );
    });
  });
}
