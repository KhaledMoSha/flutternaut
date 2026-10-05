import 'dart:math';

import 'package:flutter/widgets.dart';

import '../app_identity.dart';
import '../bridge_port.dart';
import '../engine/main_thread_runner.dart';
import '../engine/tree_walker.dart';
import '../process_environment.dart';
import '../router.dart';

/// Handles health check and tree inspection endpoints.
class HealthHandler {
  /// Bridge protocol version. Bump when the request/response shapes change
  /// so clients can detect incompatibility.
  ///
  /// 1.3.0 — the bridge binds the port named by `FLUTTERNAUT_BRIDGE_PORT`
  /// when that variable is set, and `/health` says where it is: `port` (the
  /// TCP port this bridge is bound to, always) and `device_id` (the iOS
  /// simulator's UDID; absent anywhere else). A client that chose a port
  /// for one simulator can prove the answer came from that simulator's app.
  ///
  /// 1.4.0 — a `text` locator's `match` accepts `"starts_with"` (the widget's
  /// own text begins with `text`, case-insensitively) beside `"exact"` and
  /// `"contains"`, on every locator route including `/tap` and
  /// `/long_press`; any other `match` is a 400 instead of a silent exact
  /// match. `/long_press` honours `match` (it ignored it before), and the
  /// `contains` needle is normalized like the text it is compared with.
  ///
  /// 1.5.0 — one rule for a control's enabled state, shared by the
  /// `/screen` dump and the state routes: `/assert_enabled`,
  /// `/assert_disabled` and `/is_enabled` answer for the **control** that
  /// owns the matched widget (a button's label answers with the button's
  /// state; it used to read the label itself and report "enabled"), honour
  /// `match`, `semantics` and `nth`, skip pages hidden under a dialog, name
  /// the control (`control`) and mark a locator that names no control as a
  /// `final` failure. `/assert_text_equals` and `/assert_text_contains` see
  /// only visible text (they searched the whole tree). Every `nth` — taps,
  /// waits, state routes and the dump's `text_nth`/`semantics_nth` — indexes
  /// one list: the visible matches in reading order.
  ///
  /// 1.5.1 — a button's `/screen` label is visible text only (never a page
  /// kept underneath, an offstage tab, or past a scroll view / navigator),
  /// words beat a count badge or glyph, and the node reports `label_rect`
  /// (the rect of the text it was read off — what `near` anchors on);
  /// movement gestures leave the touch slop before awaiting a frame (a
  /// scroll is never a long press); a wholly off-screen tap target is
  /// refused as off screen; `type`/`clear` by label skip hidden pages.
  static const String protocolVersion = '1.5.1';

  final TreeWalker _walker;
  final MainThreadRunner _runner;
  final int? Function() _boundPort;

  /// The iOS simulator this app runs in; null on a physical iOS device,
  /// Android and desktop — the field is then left out of `/health`.
  final String? _deviceId;

  /// Random per bridge start. A client that saw one instance answer the
  /// port before launching an app, and sees the same instance after, knows
  /// the new app never bound the port — an older app still holds it.
  final String _instanceId = _randomId();

  /// Which app this bridge runs in (see [readAppIdentity]).
  final String? _app = readAppIdentity();

  /// [boundPort] reports the port the owning server is bound to (null when
  /// it is not bound); [environment] is read once, here, for the simulator
  /// UDID.
  HealthHandler({
    required TreeWalker walker,
    required MainThreadRunner runner,
    required int? Function() boundPort,
    EnvironmentReader environment = readProcessEnvironment,
  })  : _walker = walker,
        _runner = runner,
        _boundPort = boundPort,
        _deviceId = readSimulatorUdid(environment);

  static String _randomId() {
    final rnd = Random.secure();
    return List.generate(
        8, (_) => rnd.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }

  void register(BridgeRouter router) {
    router.get('/health', _health);
    router.get('/tree', _tree);
    router.get('/screen', _screen);
    router.get('/keyed', _keyed);
  }

  Future<Map<String, dynamic>> _health(BridgeRequest req) async {
    final port = _boundPort();
    if (port == null) {
      throw StateError(
        'FlutternautBridge: /health was asked for the bound port, but the '
        'bridge server is not bound to one',
      );
    }
    return {
      'status': 'ok',
      'bridge': 'flutternaut',
      'protocol_version': protocolVersion,
      'instance_id': _instanceId,
      if (_app != null) 'app': _app,
      // The port this bridge is bound to, and the iOS simulator it runs in:
      // several simulators share the host's ports, so a client checks both
      // before trusting that it reached the app it launched.
      'port': port,
      if (_deviceId != null) 'device_id': _deviceId,
      // False until the app has put its first frame on screen: a screen
      // read before then is empty (or a splash), not the app.
      'first_frame': WidgetsBinding.instance.firstFrameRasterized,
    };
  }

  Future<Map<String, dynamic>> _tree(BridgeRequest req) async {
    return _runner.run(() => _walker.dumpTree());
  }

  /// Only the widgets actually displayed on screen right now —
  /// framework scaffolding and off-screen branches pruned.
  Future<Map<String, dynamic>> _screen(BridgeRequest req) async {
    return _runner.run(() => _walker.dumpVisibleTree());
  }

  Future<Map<String, dynamic>> _keyed(BridgeRequest req) async {
    return _runner.run(() {
      final elements = _walker.findAllKeyed();
      return {
        'count': elements.length,
        'elements': elements.map((e) => e.toJson()).toList(),
      };
    });
  }
}
