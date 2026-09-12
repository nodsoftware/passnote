/// Thrown when a supplied passphrase (or the key derived from it) does not
/// decrypt a database's existing local data.
///
/// Thrown by the disk-backed engine when it opens an existing encrypted file
/// with a key that does not match. The file is left untouched — nothing is
/// quarantined or reset — so retrying with the correct passphrase succeeds.
/// The in-memory engine has nothing to validate against, so it does not throw
/// this.
class WrongPassphraseException implements Exception {
  /// Creates the exception.
  const WrongPassphraseException();

  @override
  String toString() =>
      'WrongPassphraseException: passphrase does not match existing data';
}

/// Thrown when an encryption key is supplied but the linked native SQLite
/// library is not a SQLCipher build, so the key would be silently ignored and
/// data would be written to disk in plaintext.
///
/// Conclave verifies `PRAGMA cipher_version` after keying and refuses to open
/// rather than pretend the data is encrypted. Fix the build, not the call
/// site: `package:sqlite3` selects its native library through build hooks,
/// and the SQLCipher source is chosen in the **application's root**
/// `pubspec.yaml` (the setting is read from the root package only):
///
/// ```yaml
/// hooks:
///   user_defines:
///     sqlite3:
///       source: sqlcipher
/// ```
///
/// See the "Set up platforms" guide in the documentation.
class SqlCipherUnavailableException implements Exception {
  /// Creates the exception.
  const SqlCipherUnavailableException();

  @override
  String toString() =>
      'SqlCipherUnavailableException: an encryption key was supplied but the '
      'linked SQLite library is not a SQLCipher build; the database would be '
      'stored in plaintext. Add the SQLCipher build hook to the app\'s root '
      'pubspec.yaml (hooks: user_defines: sqlite3: source: sqlcipher — see '
      'the "Set up platforms" guide) or open without a key.';
}
