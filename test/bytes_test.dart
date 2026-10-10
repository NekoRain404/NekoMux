import 'package:flutter_test/flutter_test.dart';
import 'package:neko_mux/core/format/bytes.dart';

/// Guards the size formatter the container and disk views share.
///
/// A formatter is easy to get subtly wrong in ways nobody notices until the
/// number matters. Two of those are pinned here: the labels have to be binary
/// because the arithmetic is, and the rounding has to stop before the text
/// outgrows a phone's column.
void main() {
  test('small counts keep their exact figure', () {
    expect(formatBytes(1), '1 B');
    expect(formatBytes(512), '512 B');
    expect(formatBytes(1023), '1023 B');
  });

  test('steps up at each power of 1024', () {
    expect(formatBytes(1024), '1.0 KiB');
    expect(formatBytes(1024 * 1024), '1.0 MiB');
    expect(formatBytes(1024 * 1024 * 1024), '1.0 GiB');
    expect(formatBytes(1024 * 1024 * 1024 * 1024), '1.0 TiB');
  });

  test('labels are binary, because the arithmetic is', () {
    // 1024 bytes is a kibibyte. Labelling it `KB` would be wrong by 2.4% here
    // and by much more further up, and this formatter exists to report how full
    // a disk is — a number the user acts on.
    expect(formatBytes(1024), contains('KiB'));
    expect(formatBytes(1024), isNot(contains('KB')));
    expect(formatBytes(1024 * 1024), isNot(contains('MB')));
  });

  test('keeps one decimal while it distinguishes two sizes', () {
    expect(formatBytes(1536), '1.5 KiB');
    expect(formatBytes(1572864), '1.5 MiB');
    expect(formatBytes(99 * 1024), '99.0 KiB');
  });

  test('drops the fraction once the number is wide enough', () {
    // `125.4 GiB` and `125 GiB` lead to the same decision, and the extra digits
    // cost width a phone column does not have.
    expect(formatBytes(107374182400), '100 GiB');
    expect(formatBytes(134690000000), '125 GiB');
  });

  test('zero is a measurement, not a word', () {
    // A caller that means something else by zero says so itself: the container
    // detail view renders "Unlimited" for a memory limit of 0, and only it
    // knows whether its zero is a measurement or the absence of one.
    expect(formatBytes(0), '0 B');
    expect(
      formatBytes(-1),
      '0 B',
      reason: 'a negative size is not a size and must not carry a unit',
    );
  });
}
