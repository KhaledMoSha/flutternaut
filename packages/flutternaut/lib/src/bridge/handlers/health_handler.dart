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
  ///
  /// 1.6.0 — a `semantics` locator also matches a `Semantics.identifier`
  /// (exact, then case-insensitive, like a label), on every locator route;
  /// a `/screen` node carries `semantics_id` when a `Semantics` with the
  /// same bounds names it (never one borrowed from a section around it),
  /// with `semantics_id_nth`/`semantics_id_matches` when the identifier
  /// repeats. `near` searches through containers — a page-tall detector
  /// (an app-wide long-press layer) or a tile labelled by its inner text —
  /// instead of stopping at the outermost unlabeled control.
  ///
  /// 1.6.1 — `/swipe` takes `fling` (default `true`): with `false` the
  /// pointer stops before it lifts, so a scroll view moves about `distance`
  /// and does not fling on (the engine's `scroll` and `scroll_until_visible`
  /// send it; its `swipe` keeps the fling).
  ///
  /// 1.7.0 — the scrollables `/screen` numbers (`scrollIndex`), `/swipe`
  /// resolves by `scrollIndex` and the direction-only auto-pick chooses
  /// from are exactly the dump's scrollable nodes: a list on a route hidden
  /// behind a page, dialog, sheet or menu, on a closing route, or covered
  /// at every point takes no number and is no candidate. A `scrollIndex`
  /// recorded against an older bridge can shift, only down. A scroll
  /// gesture starts at a visible point of the list that takes the pointer
  /// (refused when there is none), and the none-visible error names what
  /// may be in the way instead of suggesting a key. A layer covers a widget
  /// only where it paints, so widgets under a page-wide tap layer that
  /// draws a banner elsewhere are visible. A request may name the app it is
  /// meant for in the `X-Flutternaut-App` header (the `app` of `/health`);
  /// the bridge of another app refuses it with 409 and runs nothing
  /// (`/health` always answers), and every response names the app that
  /// answered in the same header.
  ///
  /// 1.8.0 — a widget is on screen only when at least 1 logical px of it
  /// shows on both sides after clipping (`TreeWalkerGeometry.minVisibleSide`).
  /// A sub-pixel sliver — the 0.00002 px remainder of a `PageView` page at
  /// the screen's edge, a wrapper positioned at the edge — is no `/screen`
  /// node (its children are judged on their own rects), takes no
  /// `scrollIndex` and no `nth`, is no `/swipe` or `near` candidate, is not
  /// visible or `on_screen` to `/is_visible`, and a tap on it is refused as
  /// off screen. A `scrollIndex` or text `nth` recorded against an older
  /// bridge can shift, only down. The direction-only auto-pick ranks lists
  /// by their visible (clipped) area, not their whole rect. A `/swipe` that
  /// acted on a resolved scrollable reports `moved` (logical px the most
  /// any list sharing the drag moved) and `room` (whether it had more than
  /// 1 px to move that way before the gesture); `/is_visible` reports
  /// `reason` when not visible.
  static const String protocolVersion = '1.8.0';

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

  /// Which app this bridge runs in (see [readAppIdentity]); null when the
  /// platform does not say.
  final String? _app;

  /// [boundPort] reports the port the owning server is bound to (null when
  /// it is not bound); [environment] is read once, here, for the simulator
  /// UDID; [app] is the app this bridge runs in — the same value the router
  /// compares a request's `X-Flutternaut-App` with.
  HealthHandler({
    required TreeWalker walker,
    required MainThreadRunner runner,
    required int? Function() boundPort,
    required String? app,
    EnvironmentReader environment = readProcessEnvironment,
  })  : _walker = walker,
        _runner = runner,
        _boundPort = boundPort,
        _app = app,
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
