import 'package:flutter/material.dart';
import 'package:flutternaut/flutternaut.dart';

import 'control_flow_screen.dart';
import 'device_screen.dart';
import 'gestures_screen.dart';

class TodoItem {
  String text;
  bool completed;

  TodoItem({required this.text, this.completed = false});
}

@FlutternautView('Home')
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _todoController = TextEditingController();
  final List<TodoItem> _todos = [
    TodoItem(text: 'Buy groceries'),
    TodoItem(text: 'Read a book'),
  ];

  void _addTodo() {
    final text = _todoController.text.trim();
    if (text.isEmpty) return;
    setState(() {
      _todos.add(TodoItem(text: text));
      _todoController.clear();
    });
    FocusManager.instance.primaryFocus?.unfocus();
  }

  void _toggleTodo(int index) {
    setState(() {
      _todos[index].completed = !_todos[index].completed;
    });
  }

  void _deleteTodo(int index) {
    setState(() {
      _todos.removeAt(index);
    });
  }

  @override
  void dispose() {
    _todoController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: const Text('My Todos'),
        automaticallyImplyLeading: false,
        actions: [
          IconButton(
            key: const ValueKey('gestures_button'),
            icon: const Icon(Icons.touch_app),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const GesturesScreen()),
            ),
          ),
          IconButton(
            key: const ValueKey('device_button'),
            icon: const Icon(Icons.devices),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const DeviceScreen()),
            ),
          ),
          IconButton(
            key: const ValueKey('flow_button'),
            icon: const Icon(Icons.account_tree),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const ControlFlowScreen()),
            ),
          ),
          IconButton(
            key: const ValueKey('logout_button'),
            icon: const Icon(Icons.logout),
            onPressed: () => Navigator.pop(context),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const ValueKey('todo_input'),
                    controller: _todoController,
                    decoration: const InputDecoration(
                      hintText: 'Add a todo...',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  key: const ValueKey('add_button'),
                  onPressed: _addTodo,
                  child: const Text('Add'),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '${_todos.length} items',
                key: const ValueKey('todo_count'),
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: ListView.builder(
              itemCount: _todos.length,
              itemBuilder: (context, index) {
                final todo = _todos[index];
                return Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8.0,
                    vertical: 4.0,
                  ),
                  child: ListTile(
                    leading: Checkbox(
                      key: ValueKey('check_$index'),
                      value: todo.completed,
                      onChanged: (_) => _toggleTodo(index),
                    ),
                    title: Text(
                      todo.text,
                      key: ValueKey('todo_text_$index'),
                      style: TextStyle(
                        decoration: todo.completed
                            ? TextDecoration.lineThrough
                            : TextDecoration.none,
                      ),
                    ),
                    trailing: IconButton(
                      key: ValueKey('delete_$index'),
                      icon: const Icon(Icons.delete, color: Colors.red),
                      onPressed: () => _deleteTodo(index),
                    ),
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
