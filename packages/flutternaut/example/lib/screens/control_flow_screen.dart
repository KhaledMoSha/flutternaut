import 'package:flutter/material.dart';
import 'package:flutternaut/flutternaut.dart';

@FlutternautView('ControlFlow')
class ControlFlowScreen extends StatefulWidget {
  const ControlFlowScreen({super.key});

  @override
  State<ControlFlowScreen> createState() => _ControlFlowScreenState();
}

class _ControlFlowScreenState extends State<ControlFlowScreen> {
  int _counter = 0;
  bool _showMessage = false;
  bool _delayedVisible = false;
  final List<String> _items = List.generate(5, (i) => 'Item $i');

  void _startTimer() {
    setState(() => _delayedVisible = false);
    Future.delayed(const Duration(seconds: 3), () {
      if (mounted) setState(() => _delayedVisible = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: const Text('Control Flow Demo'),
      ),
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sectionTitle('Counter (repeat_n_times)'),
            _buildCounterSection(),
            const Divider(),
            _sectionTitle('Conditional (if)'),
            _buildConditionalSection(),
            const Divider(),
            _sectionTitle('Delayed Element (repeat_until_visible)'),
            _buildDelayedSection(),
            const Divider(),
            _sectionTitle('Numbered List (iterate_over_list)'),
            _buildNumberedListSection(),
            const Divider(),
            _sectionTitle('Long Scroll (scroll_until_visible)'),
            _buildScrollSection(),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  Widget _sectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Text(
        title,
        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
      ),
    );
  }

  Widget _buildCounterSection() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Counter: $_counter',
            key: const ValueKey('counter_value'),
          ),
          const SizedBox(height: 8),
          ElevatedButton(
            key: const ValueKey('increment_button'),
            onPressed: () => setState(() => _counter++),
            child: const Text('Increment'),
          ),
        ],
      ),
    );
  }

  Widget _buildConditionalSection() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ElevatedButton(
            key: const ValueKey('toggle_message_button'),
            onPressed: () => setState(() => _showMessage = !_showMessage),
            child: Text(_showMessage ? 'Hide Message' : 'Show Message'),
          ),
          const SizedBox(height: 8),
          if (_showMessage)
            Container(
              key: const ValueKey('conditional_message'),
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.green.shade100,
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text('Hello from conditional!'),
            ),
        ],
      ),
    );
  }

  Widget _buildDelayedSection() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ElevatedButton(
            key: const ValueKey('start_timer_button'),
            onPressed: _startTimer,
            child: const Text('Start 3s Timer'),
          ),
          const SizedBox(height: 8),
          if (_delayedVisible)
            Container(
              key: const ValueKey('delayed_element'),
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.blue.shade100,
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text('Appeared!'),
            ),
        ],
      ),
    );
  }

  Widget _buildNumberedListSection() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${_items.length} items',
            key: const ValueKey('list_count'),
          ),
          const SizedBox(height: 4),
          ...List.generate(
            _items.length,
            (index) => ListTile(
              key: ValueKey('numbered_item_$index'),
              dense: true,
              leading: Text('#$index'),
              title: Text(_items[index]),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildScrollSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 400,
          child: KeyedSubtree(
            key: const ValueKey('flow_scroll_list'),
            child: ListView.builder(
              itemCount: 51,
              itemExtent: 48,
              itemBuilder: (context, index) {
                if (index == 50) {
                  return const ListTile(
                    key: ValueKey('hidden_at_bottom'),
                    dense: true,
                    title: Text('Found me!'),
                    leading: Icon(Icons.star, color: Colors.amber),
                  );
                }
                return ListTile(
                  key: ValueKey('flow_scroll_item_$index'),
                  dense: true,
                  title: Text('Scroll Item $index'),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}
