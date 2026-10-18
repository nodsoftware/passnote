/// Passnote for Flutter apps: the full library plus platform adapters.
///
/// Re-exports `package:passnote` (the engine), `package:passnote_crypto`, and
/// `package:passnote_lan`, and adds the Flutter-only pieces — a keychain-backed
/// key store, a `ChangeNotifier` view of a collection, and [passnoteBuilder]
/// for batteries-included setup. A Flutter app can depend on this package
/// alone.
library passnote_flutter;

export 'package:passnote/passnote.dart';
export 'package:passnote_crypto/passnote_crypto.dart';
export 'package:passnote_lan/discovery.dart';

export 'src/collection_notifier.dart';
export 'src/passnote_builder.dart';
export 'src/keychain_key_store.dart';
