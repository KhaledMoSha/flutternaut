import 'package:flutter/material.dart';

import 'screens/login_screen.dart';

void main() {
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
