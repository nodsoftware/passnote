import 'package:conclave/conclave.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'item.dart';

final _codec = JsonCodec<Item>(
  toMap: (i) => i.toJson(),
  fromMap: Item.fromJson,
  idOf: (i) => i.id,
);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final conclave = await openDefault(appId: 'shopping', salt: 'shopping:v1');
  // For the demo we use a fixed passphrase so a second device can pair by
  // entering the same words. A real app would generate one and let the user
  // share it: `final words = conclave.generatePassphrase().join(' ');`
  const passphrase =
      'legal winner thank year wave sausage worth useful legal winner thank yellow';
  final db = await conclave.openDatabase('home', passphrase: passphrase);
  final items = db.collection<Item>('items', _codec);

  runApp(_ShoppingApp(items: items));
}

class _ShoppingApp extends StatelessWidget {
  const _ShoppingApp({required this.items});

  final Collection<Item> items;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Shopping List (Provider)',
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.teal),
      home: ChangeNotifierProvider(
        create: (_) => CollectionNotifier<Item>(items),
        child: _ShoppingPage(items: items),
      ),
    );
  }
}

class _ShoppingPage extends StatefulWidget {
  const _ShoppingPage({required this.items});

  final Collection<Item> items;

  @override
  State<_ShoppingPage> createState() => _ShoppingPageState();
}

class _ShoppingPageState extends State<_ShoppingPage> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final name = _controller.text.trim();
    if (name.isEmpty) return;
    await widget.items.put(Item(id: newId(), name: name));
    _controller.clear();
  }

  @override
  Widget build(BuildContext context) {
    final notifier = context.watch<CollectionNotifier<Item>>();
    final list = [...notifier.items]..sort((a, b) => a.name.compareTo(b.name));

    return Scaffold(
      appBar: AppBar(title: const Text('Shopping List (Provider)')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    decoration: const InputDecoration(
                      labelText: 'Add item',
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => _add(),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(onPressed: _add, child: const Text('Add')),
              ],
            ),
          ),
          Expanded(
            child: list.isEmpty
                ? const Center(child: Text('No items yet'))
                : ListView.builder(
                    itemCount: list.length,
                    itemBuilder: (context, index) {
                      final item = list[index];
                      return CheckboxListTile(
                        title: Text(
                          item.name,
                          style: TextStyle(
                            decoration: item.done
                                ? TextDecoration.lineThrough
                                : null,
                          ),
                        ),
                        value: item.done,
                        onChanged: (value) => widget.items
                            .put(item.copyWith(done: value ?? false)),
                        secondary: IconButton(
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () => widget.items.delete(item.id),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
