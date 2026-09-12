// Pins the pure-Dart setup story end to end: the installed defaults open a
// real SQLCipher-backed database through the builder, the GENERATED merge
// strategy gives the counter field its semantics, the file key store carries
// the key across a restart, and the default strategy's increment fails
// loudly instead of silently doing nothing.
import 'dart:convert';
import 'dart:io';

import 'package:cli_logbook/logbook.dart';
import 'package:conclave/conclave.dart';
import 'package:conclave/engine.dart' show InMemoryBus, InMemoryTransport;
import 'package:test/test.dart';

void main() {
  late Directory dir;
  late InMemoryBus bus;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('logbook_test');
    bus = InMemoryBus();
    installLogbookDefaults(dir);
  });
  tearDown(() => dir.deleteSync(recursive: true));

  Future<Conclave> open() => Conclave.builder(appId: 'lbt', salt: 'lbt:v1')
      // The LAN transport needs a network; the test overrides just that slot.
      .transport(() => InMemoryTransport(bus))
      .open();

  test(
      'generated merge strategy wires the counter; data and key survive a '
      'restart', () async {
    var conclave = await open();
    final words = conclave.generatePassphrase().join(' ');
    var db = await conclave.openDatabase('book', passphrase: words);
    if (db.deviceState != DeviceState.ready) await db.foundGroup();

    var entries =
        db.collection<Entry>('entries', entryCodec, merge: entryMerge);
    await entries.put(const Entry(id: 'e1', text: 'first light'));
    await entries.increment('e1', 'stars');
    await entries.increment('e1', 'stars');
    expect((await entries.get('e1'))?.stars, 2,
        reason: 'the generated _\$EntryMergeStrategy makes stars a counter');

    // Without the generated strategy the same call must fail loudly: a
    // counter on the default whole-document strategy has no field rows.
    final untyped = db.collection<Entry>('untyped', entryCodec);
    await untyped.put(const Entry(id: 'e1', text: 'x'));
    await expectLater(untyped.increment('e1', 'stars'), throwsArgumentError);

    await conclave.close();

    // Restart: the FileKeyStore holds the key, so no passphrase is needed,
    // and the SQLCipher files reopen with the counter intact.
    conclave = await open();
    db = await conclave.reopenDatabase('book');
    entries = db.collection<Entry>('entries', entryCodec, merge: entryMerge);
    final entry = await entries.get('e1');
    expect(entry?.text, 'first light');
    expect(entry?.stars, 2);
    await conclave.close();
  });

  test('a second device pairs with the code and sees entries written before it',
      () async {
    // Two devices, each with its own data directory and therefore its own key
    // file and device identity. The defaults are read when open() runs, so
    // installing again between the two opens is what separates them.
    final dirB = Directory.systemTemp.createTempSync('logbook_test_b');
    addTearDown(() => dirB.deleteSync(recursive: true));

    final phone = await open();
    addTearDown(phone.close);
    final words = phone.generatePassphrase().join(' ');
    final book = await phone.openDatabase('book', passphrase: words);
    if (book.deviceState != DeviceState.ready) await book.foundGroup();
    final onPhone =
        book.collection<Entry>('entries', entryCodec, merge: entryMerge);
    await onPhone.put(const Entry(id: 'e1', text: 'written before pairing'));

    installLogbookDefaults(dirB);
    final laptop = await Conclave.builder(appId: 'lbt', salt: 'lbt:v1')
        .transport(() => InMemoryTransport(bus))
        .open();
    addTearDown(laptop.close);

    final code = await phone.startPairing('book', joinerLabel: 'laptop');
    final bookOnLaptop =
        await laptop.pairWith('book', PairingCode.parse(code.display));
    expect(bookOnLaptop.deviceState, DeviceState.ready);

    // No forceSync: what the sponsor already held must arrive on its own.
    final onLaptop = bookOnLaptop.collection<Entry>('entries', entryCodec,
        merge: entryMerge);
    final synced = await onLaptop
        .watch()
        .firstWhere((all) => all.isNotEmpty)
        .timeout(const Duration(seconds: 5));
    expect(synced.single.text, 'written before pairing');

    // The counter still merges per device once both hold the collection.
    await onPhone.increment('e1', 'stars');
    await onLaptop.increment('e1', 'stars', by: 2);
    await laptop.forceSync();
    await phone.forceSync();
    final settled = await onPhone
        .watch()
        .firstWhere((all) => all.single.stars == 3)
        .timeout(const Duration(seconds: 5));
    expect(settled.single.stars, 3);
  });

  test('the key file never holds plaintext data and the database is opaque',
      () async {
    final conclave = await open();
    final words = conclave.generatePassphrase().join(' ');
    final db = await conclave.openDatabase('book', passphrase: words);
    if (db.deviceState != DeviceState.ready) await db.foundGroup();
    final entries =
        db.collection<Entry>('entries', entryCodec, merge: entryMerge);
    await entries.put(const Entry(id: 'e1', text: 'TOP-SECRET-ENTRY'));
    await conclave.close();

    for (final file in dir.listSync(recursive: true).whereType<File>()) {
      final content = latin1.decode(file.readAsBytesSync(), allowInvalid: true);
      expect(content, isNot(contains('TOP-SECRET-ENTRY')),
          reason: '${file.path} must not hold plaintext document data');
    }
  });
}
