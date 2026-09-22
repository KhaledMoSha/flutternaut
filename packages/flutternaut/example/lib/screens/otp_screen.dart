import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutternaut/flutternaut.dart';

/// A PIN / OTP entry the way most packages build it (`PinCodeTextField`,
/// `Pinput`): the real [TextField] is invisible under a row of digit boxes,
/// tapping a box focuses it, and typing fills the boxes. A pointer can never
/// reach the field — the boxes are what is hittable — so a test fills it
/// with `type_focused` after tapping a box.
@FlutternautView('Otp')
class OtpScreen extends StatefulWidget {
  const OtpScreen({super.key});

  @override
  State<OtpScreen> createState() => _OtpScreenState();
}

class _OtpScreenState extends State<OtpScreen> {
  static const _length = 4;
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  String _status = '';

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onChanged);
  }

  void _onChanged() {
    setState(() {
      if (_controller.text.length == _length) {
        _status = _controller.text == '1234' ? 'Verified' : 'Wrong code';
      } else {
        _status = '';
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final digits = _controller.text;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: const Text('Enter code'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text('Enter the 4-digit code we sent you'),
            const SizedBox(height: 24),
            Stack(
              alignment: Alignment.center,
              children: [
                // The real input: laid out, focusable, invisible.
                Opacity(
                  opacity: 0,
                  child: TextField(
                    key: const ValueKey('otp_input'),
                    controller: _controller,
                    focusNode: _focusNode,
                    keyboardType: TextInputType.number,
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(_length),
                    ],
                  ),
                ),
                // The visible boxes; tapping any of them focuses the input.
                GestureDetector(
                  key: const ValueKey('otp_boxes'),
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _focusNode.requestFocus(),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      for (var i = 0; i < _length; i++)
                        Container(
                          width: 48,
                          height: 56,
                          margin: const EdgeInsets.symmetric(horizontal: 6),
                          decoration: BoxDecoration(
                            border: Border.all(
                              color: _focusNode.hasFocus && i == digits.length
                                  ? Theme.of(context).colorScheme.primary
                                  : Colors.grey,
                              width: 2,
                            ),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            i < digits.length ? digits[i] : '',
                            style: const TextStyle(fontSize: 24),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            Text(
              _status,
              key: const ValueKey('otp_status'),
              style: TextStyle(
                fontSize: 18,
                color: _status == 'Verified' ? Colors.green : Colors.red,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
