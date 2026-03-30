import 'package:flutter/material.dart';
import 'package:flutternaut/flutternaut.dart';

@FlutternautView('Gestures')
class GesturesScreen extends StatefulWidget {
  const GesturesScreen({super.key});

  @override
  State<GesturesScreen> createState() => _GesturesScreenState();
}

class _GesturesScreenState extends State<GesturesScreen> {
  int _lastVisibleIndex = 0;
  final List<String> _swipeItems = [
    'Swipe Item 1',
    'Swipe Item 2',
    'Swipe Item 3'
  ];
  String _longPressStatus = 'Not pressed';
  int _doubleTapCount = 0;
  String _dragStatus = 'Not dragged';
  bool _dragSourceVisible = true;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: const Text('Gestures Demo'),
      ),
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sectionTitle('Scroll Test'),
            _buildScrollSection(),
            const Divider(),
            _sectionTitle('Swipe Test'),
            _buildSwipeSection(),
            const Divider(),
            _sectionTitle('Long Press Test'),
            _buildLongPressSection(),
            const Divider(),
            _sectionTitle('Double Tap Test'),
            _buildDoubleTapSection(),
            const Divider(),
            _sectionTitle('Drag & Drop Test'),
            _buildDragDropSection(),
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

  Widget _buildScrollSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Flutternaut.text(
            label: 'scroll_result',
            value: 'Last visible: $_lastVisibleIndex',
            child: Text('Last visible: $_lastVisibleIndex'),
          ),
        ),
        const SizedBox(height: 4),
        SizedBox(
          height: 200,
          child: Flutternaut.item(
            label: 'scroll_list',
            child: NotificationListener<ScrollNotification>(
              onNotification: (notification) {
                if (notification is ScrollUpdateNotification) {
                  final index = (notification.metrics.pixels / 48).floor();
                  if (index != _lastVisibleIndex) {
                    setState(() => _lastVisibleIndex = index.clamp(0, 19));
                  }
                }
                return false;
              },
              child: ListView.builder(
                itemCount: 20,
                itemExtent: 48,
                itemBuilder: (context, index) {
                  return Flutternaut.text(
                    label: 'scroll_item_$index',
                    value: 'Item $index',
                    child: ListTile(dense: true, title: Text('Item $index')),
                  );
                },
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSwipeSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Flutternaut.text(
            label: 'swipe_count',
            value: '${_swipeItems.length} items',
            child: Text('${_swipeItems.length} items'),
          ),
        ),
        const SizedBox(height: 4),
        ..._swipeItems.asMap().entries.map((entry) {
          final index = entry.key;
          final item = entry.value;
          return Flutternaut.text(
            label: 'swipe_item_$index',
            value: item,
            child: Dismissible(
              key: ValueKey(item),
              direction: DismissDirection.endToStart,
              onDismissed: (_) {
                setState(() => _swipeItems.remove(item));
              },
              background: Container(
                color: Colors.red,
                alignment: Alignment.centerRight,
                padding: const EdgeInsets.only(right: 16),
                child: const Icon(Icons.delete, color: Colors.white),
              ),
              child: ListTile(
                dense: true,
                title: Text(item),
                trailing: const Icon(Icons.swipe_left, size: 16),
              ),
            ),
          );
        }),
      ],
    );
  }

  Widget _buildLongPressSection() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Flutternaut.text(
            label: 'long_press_status',
            value: _longPressStatus,
            child: Text('Status: $_longPressStatus'),
          ),
          const SizedBox(height: 8),
          Flutternaut.button(
            label: 'long_press_target',
            child: GestureDetector(
              onLongPress: () {
                setState(() => _longPressStatus = 'Long pressed!');
              },
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.blue.shade100,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Text('Long press me', textAlign: TextAlign.center),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDoubleTapSection() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Flutternaut.text(
            label: 'double_tap_count',
            value: '$_doubleTapCount',
            child: Text('Count: $_doubleTapCount'),
          ),
          const SizedBox(height: 8),
          Flutternaut.button(
            label: 'double_tap_target',
            child: GestureDetector(
              onDoubleTap: () {
                setState(() => _doubleTapCount++);
              },
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.green.shade100,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Text('Double tap me', textAlign: TextAlign.center),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDragDropSection() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Flutternaut.text(
            label: 'drag_status',
            value: _dragStatus,
            child: Text('Status: $_dragStatus'),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              Flutternaut.item(
                label: 'drag_source',
                child: _dragSourceVisible
                    ? LongPressDraggable<String>(
                        data: 'dragged_item',
                        feedback: Material(
                          elevation: 4,
                          child: Container(
                            width: 100,
                            height: 100,
                            color: Colors.orange.shade200,
                            child: const Center(child: Text('Dragging...')),
                          ),
                        ),
                        childWhenDragging: Container(
                          width: 100,
                          height: 100,
                          decoration: BoxDecoration(
                            color: Colors.grey.shade300,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: Colors.grey),
                          ),
                          child: const Center(child: Text('...')),
                        ),
                        child: Container(
                          width: 100,
                          height: 100,
                          decoration: BoxDecoration(
                            color: Colors.orange.shade100,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: Colors.orange),
                          ),
                          child: const Center(child: Text('Drag me')),
                        ),
                      )
                    : Container(
                        width: 100,
                        height: 100,
                        decoration: BoxDecoration(
                          color: Colors.grey.shade200,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Center(child: Text('Moved')),
                      ),
              ),
              const Icon(Icons.arrow_forward),
              Flutternaut(
                label: 'drag_target',
                child: DragTarget<String>(
                  onAcceptWithDetails: (details) {
                    setState(() {
                      _dragStatus = 'Dropped!';
                      _dragSourceVisible = false;
                    });
                  },
                  builder: (context, candidateData, rejectedData) {
                    final isHovering = candidateData.isNotEmpty;
                    return Container(
                      width: 100,
                      height: 100,
                      decoration: BoxDecoration(
                        color: isHovering
                            ? Colors.green.shade200
                            : Colors.purple.shade100,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: isHovering ? Colors.green : Colors.purple,
                          width: isHovering ? 2 : 1,
                        ),
                      ),
                      child: Center(
                        child: Text(isHovering ? 'Drop here!' : 'Drop target'),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
