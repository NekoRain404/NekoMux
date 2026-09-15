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

  group('sftpJoinedNames', () {
    test('joins display names with a comma and a space', () {
      expect(sftpJoinedNames(['/var/a.txt', '/var/log/b.log']), 'a.txt, b.log');
    });

    test('uses no punctuation that belongs to one language', () {
      // The ideographic comma '、' used to join these names, and the sentence
      // they are substituted into comes from the i18n table in eight
      // languages — seven of which do not write lists that way. English users
      // read `Delete the following 3 files? a、b、c`.
      // 这些名字此前用中文顿号 '、' 连接，而它们被代入的句子来自八种语言的 i18n 表，
      // 其中七种并不这样书写列表。英文用户读到的是 `Delete the following 3 files? a、b、c`。
      final joined = sftpJoinedNames(['/a', '/b', '/c']);
      expect(joined, 'a, b, c');
      expect(joined.contains('、'), isFalse);
      // U+3000–U+303F, U+4E00–U+9FFF, U+FF00–U+FFEF.
      expect(
        RegExp(
          '[\\u3000-\\u303f\\u4e00-\\u9fff\\uff00-\\uffef]',
        ).hasMatch(joined),
        isFalse,
      );
    });

    test('copes with none, one, and a trailing-slash path', () {
      expect(sftpJoinedNames(const []), '');
      expect(sftpJoinedNames(['/var/log']), 'log');
      expect(sftpJoinedNames(['/var/log/']), '');
    });
  });

  group('sftpTextExtensions', () {
    test('still declares every extension the preview has always opened', () {
      // This set decides text preview versus the file actions sheet. It was
      // extracted here verbatim and must not lose an entry while the file-type
      // label moves out of the model.
      // 这个集合决定「文本预览」还是「文件操作面板」。它是原样抽取到这里的，在文件类型
      // 标签移出模型的改动中不能丢掉任何一项。
      expect(sftpTextExtensions, {
        'txt',
        'json',
        'conf',
        'log',
        'yml',
        'yaml',
        'xml',
        'ini',
        'sh',
        'py',
        'js',
        'css',
        'html',
        'php',
        'md',
      });
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
