import 'package:flutter/material.dart';
import 'package:flutternaut/flutternaut.dart';

import 'home_screen.dart';

@FlutternautView('Login')
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  String _error = '';

  void _login() async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) {
        return const Center(
          child: CircularProgressIndicator(
            key: ValueKey('loading_indicator'),
          ),
        );
      },
    );

    await Future.delayed(const Duration(seconds: 1));
    if (!mounted) return;
    Navigator.pop(context);

    final email = _emailController.text.trim();
    final password = _passwordController.text;

    if (email.isEmpty) {
      setState(() => _error = 'Email is required');
      return;
    }
    if (!email.contains('@')) {
      setState(() => _error = 'Invalid email format');
      return;
    }
    if (password.isEmpty) {
      setState(() => _error = 'Password is required');
      return;
    }
    if (password.length < 6) {
      setState(() => _error = 'Password must be at least 6 characters');
      return;
    }

    if (email == 'test@test.com' && password == 'password123') {
      setState(() => _error = '');
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const HomeScreen()),
      );
    } else {
      setState(() => _error = 'Invalid credentials');
    }
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: const Text('Login'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            TextField(
              key: const ValueKey('email_input'),
              controller: _emailController,
              decoration: const InputDecoration(
                labelText: 'Email',
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.emailAddress,
            ),
            const SizedBox(height: 16),
            TextField(
              key: const ValueKey('password_input'),
              controller: _passwordController,
              decoration: const InputDecoration(
                labelText: 'Password',
                border: OutlineInputBorder(),
              ),
              obscureText: true,
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                key: const ValueKey('login_button'),
                onPressed: _login,
                child: const Text('Login'),
              ),
            ),
            const SizedBox(height: 16),
            KeyedSubtree(
              key: const ValueKey('error_text'),
              child: _error.isNotEmpty
                  ? Text(
                      _error,
                      style: const TextStyle(color: Colors.red, fontSize: 14),
                    )
                  : const SizedBox.shrink(),
            ),
          ],
        ),
      ),
    );
  }
}
