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
          Flutternaut.button(
            label: 'gestures_button',
            child: IconButton(
              icon: const Icon(Icons.touch_app),
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const GesturesScreen()),
              ),
            ),
          ),
          Flutternaut.button(
            label: 'device_button',
            child: IconButton(
              icon: const Icon(Icons.devices),
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const DeviceScreen()),
              ),
            ),
          ),
          Flutternaut.button(
            label: 'flow_button',
            child: IconButton(
              icon: const Icon(Icons.account_tree),
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const ControlFlowScreen()),
              ),
            ),
          ),
          Flutternaut.button(
            label: 'logout_button',
            child: IconButton(
              icon: const Icon(Icons.logout),
              onPressed: () => Navigator.pop(context),
            ),
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
                  child: Flutternaut.input(
                    label: 'todo_input',
                    child: TextField(
                      controller: _todoController,
                      decoration: const InputDecoration(
                        hintText: 'Add a todo...',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Flutternaut.button(
                  label: 'add_button',
                  child: ElevatedButton(
                    onPressed: _addTodo,
                    child: const Text('Add'),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Flutternaut.text(
                label: 'todo_count',
                value: '${_todos.length} items',
                child: Text(
                  '${_todos.length} items',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
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
                    leading: Flutternaut.checkbox(
                      label: 'check_$index',
                      checked: todo.completed,
                      child: Checkbox(
                        value: todo.completed,
                        onChanged: (_) => _toggleTodo(index),
                      ),
                    ),
                    title: Flutternaut.item(
                      label: 'todo_text_$index',
                      value: todo.text,
                      child: Text(
                        todo.text,
                        style: TextStyle(
                          decoration: todo.completed
                              ? TextDecoration.lineThrough
                              : TextDecoration.none,
                        ),
                      ),
                    ),
                    trailing: Flutternaut.item(
                      label: 'delete_$index',
                      child: IconButton(
                        icon: const Icon(Icons.delete, color: Colors.red),
                        onPressed: () => _deleteTodo(index),
                      ),
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
