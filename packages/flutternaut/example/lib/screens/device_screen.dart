import 'package:flutter/material.dart';
import 'package:flutternaut/flutternaut.dart';

@FlutternautView('Device')
class DeviceScreen extends StatefulWidget {
  const DeviceScreen({super.key});

  @override
  State<DeviceScreen> createState() => _DeviceScreenState();
}

class _DeviceScreenState extends State<DeviceScreen> {
  @override
  Widget build(BuildContext context) {
    final orientation = MediaQuery.of(context).orientation;
    final orientationStr =
        orientation == Orientation.portrait ? 'portrait' : 'landscape';

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: const Text('Device Demo'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Orientation',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Flutternaut.text(
              label: 'orientation_status',
              value: orientationStr,
              child: Text('Orientation: $orientationStr'),
            ),
          ],
        ),
      ),
    );
  }
}
