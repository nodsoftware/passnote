/// Conclave for Flutter apps: the full library plus platform adapters.
///
/// Re-exports `package:conclave` (the engine), `package:conclave_crypto`, and
/// `package:conclave_lan`, and adds the Flutter-only pieces — a keychain-backed
/// key store, a `ChangeNotifier` view of a collection, and [conclaveBuilder]
/// for batteries-included setup. A Flutter app can depend on this package
/// alone.
library conclave_flutter;

export 'package:conclave/conclave.dart';
export 'package:conclave_crypto/conclave_crypto.dart';
export 'package:conclave_lan/discovery.dart';

export 'src/collection_notifier.dart';
export 'src/conclave_builder.dart';
export 'src/keychain_key_store.dart';
