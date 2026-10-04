import 'package:flutter/material.dart';
import 'package:flutternaut/flutternaut.dart';

import 'screens/login_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // On in every build mode, so the example can be tested as a debug, profile
  // or release build. Remove it from a build you publish to a store.
  await FlutternautBridge.ensureInitialized();
  runApp(const FlutternautExampleApp());
}

class FlutternautExampleApp extends StatelessWidget {
  const FlutternautExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flutternaut Example',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
      ),
      home: const LoginScreen(),
    );
  }
}
