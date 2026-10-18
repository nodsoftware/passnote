// A minimal Flutter app on Passnote: open a database, watch a collection,
// add items. The complete tutorial app lives in the repository under
// `examples/quickstart/`.
import 'package:passnote_flutter/passnote_flutter.dart';
import 'package:flutter/material.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final passnote = await passnoteBuilder(appId: 'demo', salt: 'demo:v1').open();
  final passphrase = passnote.generatePassphrase().join(' ');
  final db = await passnote.openDatabase('home', passphrase: passphrase);
  final items = db.collection<Map<String, dynamic>>(
    'items',
    JsonCodec(
        toMap: (m) => m, fromMap: (m) => m, idOf: (m) => m['id'] as String),
  );
  runApp(DemoApp(items: items));
}

/// Lists the items live and adds one per tap.
class DemoApp extends StatelessWidget {
  /// Creates the app over [items].
  const DemoApp({required this.items, super.key});

  /// The synced collection backing the list.
  final Collection<Map<String, dynamic>> items;

  @override
  Widget build(BuildContext context) => MaterialApp(
        home: Scaffold(
          body: StreamBuilder(
            stream: items.watch(),
            builder: (context, snapshot) {
              final all = snapshot.data ?? const [];
              return ListView(
                children: [
                  for (final item in all)
                    ListTile(title: Text('${item['id']}')),
                ],
              );
            },
          ),
          floatingActionButton: FloatingActionButton(
            onPressed: () => items.put({'id': newId()}),
            child: const Icon(Icons.add),
          ),
        ),
      );
}
