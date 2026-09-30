import 'package:flutter/material.dart';

/// Reproductions of what AI agents reported while driving real apps through
/// the Flutternaut MCP (2026-09-30), so each fix can be checked live:
///
///  * a looping spinner on screen (must read as MOVING CONTENT, never block
///    wait_idle);
///  * a FlutterFlow-style button whose label carries surrounding whitespace
///    (its ref must tap);
///  * a bottom nav item built from two stacked glyph layers (a text tap must
///    not be ambiguous);
///  * a banner at opacity 0 (wait_visible must not pass on it);
///  * a label partly covered by a painted badge (listed, marked partial);
///  * a tile with a transparent tap layer over its text (text still listed);
///  * a modal bottom sheet (the page beneath must leave the readout).
class LabScreen extends StatefulWidget {
  const LabScreen({super.key});

  @override
  State<LabScreen> createState() => _LabScreenState();
}

class _LabScreenState extends State<LabScreen> {
  String _status = 'idle';
  bool _bannerShown = false;
  int _tab = 0;

  void _set(String status) => setState(() => _status = status);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Agent lab')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Status: $_status'),
          const SizedBox(height: 12),
          const Row(children: [
            SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 3),
            ),
            SizedBox(width: 12),
            Text('Live feed'),
          ]),
          const SizedBox(height: 12),
          // FlutterFlow's FFButtonWidget: an InkWell-backed container whose
          // label text often carries stray whitespace.
          Material(
            color: Colors.indigo,
            borderRadius: BorderRadius.circular(8),
            child: InkWell(
              onTap: () => _set('checked in'),
              child: const Padding(
                padding: EdgeInsets.all(14),
                child: Center(
                  child: Text(
                    ' Check In \n',
                    style: TextStyle(color: Colors.white),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          // A tile with its tap layer stretched over the text.
          SizedBox(
            height: 64,
            child: Stack(children: [
              const Positioned.fill(
                child: ColoredBox(
                  color: Color(0xFFE8EAF6),
                  child: Center(child: Text("See who's around")),
                ),
              ),
              Positioned.fill(
                child: Material(
                  type: MaterialType.transparency,
                  child: InkWell(onTap: () => _set('around')),
                ),
              ),
            ]),
          ),
          const SizedBox(height: 12),
          // A label with a painted badge over its left part.
          SizedBox(
            height: 32,
            child: Stack(children: [
              const Positioned.fill(child: Text('Nearby events this week')),
              Positioned(
                left: 0,
                top: 0,
                width: 60,
                height: 16,
                child: Container(color: Colors.red),
              ),
            ]),
          ),
          const SizedBox(height: 12),
          ElevatedButton(
            onPressed: () => setState(() => _bannerShown = true),
            child: const Text('Show banner'),
          ),
          AnimatedOpacity(
            opacity: _bannerShown ? 1 : 0,
            duration: const Duration(milliseconds: 600),
            child: const Text('Up for it?'),
          ),
          const SizedBox(height: 12),
          ElevatedButton(
            onPressed: () => showModalBottomSheet<void>(
              context: context,
              builder: (sheet) => SizedBox(
                height: 200,
                child: Center(
                  child: TextButton(
                    onPressed: () => Navigator.pop(sheet),
                    child: const Text('What is Marduk?'),
                  ),
                ),
              ),
            ),
            child: const Text('Open sheet'),
          ),
        ],
      ),
      bottomNavigationBar: Row(children: [
        for (final (i, label) in const [(0, 'Radar'), (1, 'Events')].indexed)
          Expanded(
            child: InkWell(
              onTap: () => setState(() => _tab = label.$1),
              child: SizedBox(
                height: 64,
                // Two stacked layers of the same label (selected and
                // unselected), the way many custom nav bars cross-fade.
                child: Stack(alignment: Alignment.center, children: [
                  Text(label.$2),
                  Opacity(
                    opacity: _tab == i ? 1 : 0.4,
                    child: Text(label.$2),
                  ),
                ]),
              ),
            ),
          ),
      ]),
    );
  }
}
