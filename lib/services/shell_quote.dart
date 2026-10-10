// Quoting a value so a POSIX shell passes it through as one argument.
//
// One implementation, because two callers need it and a second copy would
// drift. The container form quotes the values a user types into `docker run`;
// the disk explorer quotes a path that came from a filesystem listing. A bug in
// either is the same bug — a value that escapes its argument and becomes a
// second command — so the rule is written once, tested once, and imported.

/// [value] quoted as one shell argument, or null when it cannot be.
///
/// Null for a newline or a NUL: a POSIX shell cannot put either inside single
/// quotes, and there is no safe way to pass one through this path. Refusing is
/// the honest answer — silently dropping the character would run a different
/// command from the one the user described.
///
/// A null return is not a failure the caller may ignore: it must not fall back
/// to the unquoted value, which is the injection this exists to prevent.
String? shellQuote(String value) {
  if (value.contains('\n') || value.contains('\r') || value.contains('\x00')) {
    return null;
  }
  return "'${value.replaceAll("'", r"'\''")}'";
}
