import 'package:flutter/widgets.dart';

import '../engine/main_thread_runner.dart';
import '../models/action_result.dart';
import '../router.dart';

/// Handles app control endpoints.
///
/// Deep-link navigation is intentionally NOT handled here — it's triggered
/// externally via Appium / `adb shell am start` / `xcrun simctl openurl`
/// so it exercises the real OS deep-link pipeline.
class AppHandler {
  final MainThreadRunner _runner;

  AppHandler({required MainThreadRunner runner}) : _runner = runner;

  void register(BridgeRouter router) {
    router.post('/back', _back);
  }

  /// Pops the current route. Uses [WidgetsBinding.handlePopRoute] which
  /// walks registered observers and falls back to [SystemNavigator.pop]
  /// if no route can be popped — same path as the OS back button.
  ///
  /// Flutter marks [WidgetsBinding.handlePopRoute] as `@visibleForTesting`
  /// because it simulates an OS-delivered platform message — which is
  /// exactly what this bridge exists to do. The ignore below is intentional.
  Future<Map<String, dynamic>> _back(BridgeRequest req) async {
    // ignore: invalid_use_of_visible_for_testing_member, invalid_use_of_protected_member
    await _runner.run(() => WidgetsBinding.instance.handlePopRoute());
    return const ActionResult(action: 'back', success: true).toJson();
  }
}
