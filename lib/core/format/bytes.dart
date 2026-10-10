// Turning a byte count into something a person reads.
//
// One implementation, because this session produced a second and the disk
// explorer was about to be a third, and a formatter that disagrees with itself
// about what a gigabyte is will eventually disagree about whether a disk is
// full.

/// [bytes] in the units a person would say it in.
///
/// Binary units with binary labels: 1024 bytes is `1.0 KiB`, never `1.0 KB`.
/// The two differ by 2.4%, and the error compounds at every step up — at the
/// terabyte scale it is the difference between two numbers a user would act on
/// differently, and this app reports disk sizes, where that is the whole
/// question.
///
/// The fraction is dropped once a value reaches 100 of a unit: `125.4 GiB` and
/// `125 GiB` lead to the same decision, and the extra digits are width a phone
/// does not have.
///
/// Zero is `0 B` and not a word. A caller that means something else by zero —
/// the container detail view says "Unlimited" for a memory limit of 0 — has to
/// say so itself, because only it knows whether its zero is a measurement or
/// the absence of one.
String formatBytes(int bytes) {
  if (bytes <= 0) return '0 B';

  const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB', 'PiB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }

  final text = (unit == 0 || value >= 100)
      ? value.toStringAsFixed(0)
      : value.toStringAsFixed(1);
  return '$text ${units[unit]}';
}
