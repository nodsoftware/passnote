// Guards the two public libraries. `conclave_core.dart` is the app-facing
// surface; `engine.dart` is the advanced surface. A symbol moving between them
// (task 39) should break this test on purpose.
import 'package:conclave_core/conclave_core.dart' as api;
import 'package:conclave_core/engine.dart' as engine;
import 'package:test/test.dart';

void main() {
  test('conclave_core.dart surfaces the app-facing API', () {
    // Builder entry and its config types.
    expect(api.Conclave.builder, isA<Function>());
    expect(api.ConclaveBuilder, isNotNull);
    expect(api.ConclaveDefaults, isNotNull);
    expect(const api.ConclaveConfig(appId: 'a', salt: 's').appId, 'a');
    expect(const api.PassphrasePolicy().words, 24);
    expect(api.PassphraseStrictness.warn, isNotNull);

    // Data model.
    expect(api.Database, isNotNull);
    expect(api.Collection, isNotNull);
    expect(api.newId(), isNotEmpty);
    expect(const api.ObjectMergeStrategy(), isA<api.MergeStrategy>());
    expect(const api.ShallowMergeStrategy(), isA<api.MergeStrategy>());
    expect(const api.DeepMergeStrategy(), isA<api.MergeStrategy>());

    // Exceptions.
    expect(const api.WrongPassphraseException().toString(),
        contains('passphrase'));
    expect(
        const api.WeakPassphraseException().toString(), contains('mnemonic'));
    expect(const api.CipherAuthError().toString(), contains('authentication'));
  });

  test('engine.dart surfaces the advanced wiring and ports', () {
    expect(engine.Conclave.lowLevel, isA<Function>());
    expect(engine.MapCrdtTable('t'), isA<engine.CrdtTable>());
    expect(engine.InMemoryTransport(engine.InMemoryBus()),
        isA<engine.Transport>());
    // Port types resolve.
    expect(engine.BlobStore, isNotNull);
    expect(engine.Cipher, isNotNull);
    expect(engine.KeyStore, isNotNull);
  });
}
