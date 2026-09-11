// Two stores converge by exchanging changesets: the merge is idempotent and
// order-independent, which is the property everything else builds on. A real
// app opens collections through `conclaveBuilder` (package:conclave_flutter)
// or `Conclave.builder`; a real deployment stores in `SqliteCrdtTable` and
// syncs over a transport.
import 'package:conclave/engine.dart';

Future<void> main() async {
  final alice = MapCrdtTable('todos');
  final bob = MapCrdtTable('todos');

  await alice.put('todos', 'milk', {'title': 'Milk', 'done': false});
  await bob.put('todos', 'bread', {'title': 'Bread', 'done': true});

  await bob.merge(await alice.changeset('todos'));
  await alice.merge(await bob.changeset('todos'));

  print(await alice.value('todos', 'bread')); // {title: Bread, done: true}
  print(await bob.value('todos', 'milk')); // {title: Milk, done: false}
}
