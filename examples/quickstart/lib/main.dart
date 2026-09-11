// The tutorial, compiled. Each numbered section matches a step in
// docs/start-here/tutorial.md; keep the two in sync.

import 'package:conclave_flutter/conclave_flutter.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

part 'main.g.dart';

// 2. Define a model — the codec is generated

@Document()
class Item {
  const Item({required this.id, required this.name, this.done = false});

  @DocumentId()
  final String id;

  final String name;
  final bool done;

  Item copyWith({String? name, bool? done}) =>
      Item(id: id, name: name ?? this.name, done: done ?? this.done);
}

// `dart run build_runner build` generates _$ItemCodec from the annotations:
// toMap/fromMap over the fields, with `id` as the document id.
final itemCodec = _$ItemCodec;

// 3. Open Conclave and 4. open a database with a passphrase

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final conclave = await conclaveBuilder(
    appId: 'shopping', // scopes discovery + storage
    salt: 'shopping:v1', // stable, app-specific PBKDF2 salt
  )
      // Override any default before open(). This one is optional.
      .compactionHorizon(const Duration(days: 60))
      .open();

  // On the first device, generate a passphrase to show the user:
  final words = conclave.generatePassphrase().join(' ');

  // On every device, open the database with that passphrase:
  final db = await conclave.openDatabase('home', passphrase: words);

  final items = db.collection<Item>('items', itemCodec);

  await seed(items);
  logChanges(items);

  runApp(ShoppingList(items: items));
}

// 5. Read and write a collection

Future<void> seed(Collection<Item> items) async {
  await items.put(Item(id: newId(), name: 'Milk'));
  await items.put(Item(id: newId(), name: 'Bread'));

  // Soft-delete by id:
  final someId = itemCodec.idOf((await items.all()).first);
  await items.delete(someId);

  // Query by scanning the decoded documents:
  final remaining = await items.where((i) => !i.done);
  debugPrint('${remaining.length} item(s) still to buy');
}

// 6. React to changes

void logChanges(Collection<Item> items) {
  items.watch().listen((all) {
    debugPrint('list now has ${all.length} items');
  });
}

// 7. Pair a second device

Future<void> sponsorPairing(Conclave conclave) async {
  // On a device that already has the data: create a one-time code.
  final code = await conclave.startPairing('home', joinerLabel: 'new phone');
  debugPrint('On the new device, enter: ${code.display}');
}

Future<Database> joinWithCode(Conclave conclave, String typedCode) {
  // On the new device: enter the code. The exchange authenticates both
  // sides, hands over the keys, and returns a ready database.
  return conclave.pairWith('home', PairingCode.parse(typedCode));
}

class ShoppingList extends StatelessWidget {
  const ShoppingList({required this.items, super.key});

  final Collection<Item> items;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: ChangeNotifierProvider(
          create: (_) => CollectionNotifier<Item>(items),
          child: Consumer<CollectionNotifier<Item>>(
            builder: (_, n, __) => ListView(
              children: [for (final item in n.items) Text(item.name)],
            ),
          ),
        ),
      ),
    );
  }
}
