import 'dart:math';

import 'package:conclave/conclave.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'item.dart';
import 'shopping_cubit.dart';

final _codec = JsonCodec<Item>(
  toJson: (i) => i.toJson(),
  fromJson: Item.fromJson,
  id: (i) => i.id,
);

String _newId() {
  final rand = Random();
  return '${DateTime.now().microsecondsSinceEpoch}-${rand.nextInt(1 << 32)}';
}

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
      title: 'Shopping List (BLoC)',
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.indigo),
      home: BlocProvider(
        create: (_) => ShoppingCubit(items),
        child: const _ShoppingPage(),
      ),
    );
  }
}

class _ShoppingPage extends StatefulWidget {
  const _ShoppingPage();

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

  void _add() {
    final name = _controller.text.trim();
    if (name.isEmpty) return;
    context.read<ShoppingCubit>().add(Item(id: _newId(), name: name));
    _controller.clear();
  }

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<ShoppingCubit>();
    return Scaffold(
      appBar: AppBar(title: const Text('Shopping List (BLoC)')),
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
            child: BlocBuilder<ShoppingCubit, List<Item>>(
              builder: (context, items) {
                if (items.isEmpty) {
                  return const Center(child: Text('No items yet'));
                }
                return ListView.builder(
                  itemCount: items.length,
                  itemBuilder: (context, index) {
                    final item = items[index];
                    return CheckboxListTile(
                      title: Text(
                        item.name,
                        style: TextStyle(
                          decoration:
                              item.done ? TextDecoration.lineThrough : null,
                        ),
                      ),
                      value: item.done,
                      onChanged: (_) => cubit.toggle(item),
                      secondary: IconButton(
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => cubit.remove(item.id),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
