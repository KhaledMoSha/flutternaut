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
  ///
  /// 1.8.1 — wording only: a gated action (`tap`, `long_press`, `type`, …)
  /// whose one match sits on a page, dialog or sheet hidden behind another
  /// route says so (`… is on a page hidden behind the page on top — it
  /// cannot be acted on until that page closes`) instead of "occluded or
  /// off-screen". Same refusal, same retry; no engine gate.
  ///
  /// 1.8.2 — the tap gate no longer passes a tap that would do nothing. A
  /// label under an ancestor whose own hit test refuses the pointer (a
  /// `Skeletonizer` with `ignorePointers` drawing a loading page's
  /// placeholder rows, any custom `hitTest` returning false, box or sliver)
  /// is refused as taking no taps, naming that ancestor; so is a label whose
  /// frontmost hit is an ancestor that handles no taps (a page's `Material`).
  /// The engine re-tries the refusal for the step's timeout, so the tap lands
  /// on the real row once the page has loaded. A non-control the pointer
  /// reached is named with only its own text, never the first text under it.
  /// No engine gate.
  ///
  /// 1.9.0 — a control's selection state. A `/screen` node that carries
  /// `enabled` also carries `selected` (true / false) when the control it
  /// belongs to declares one, or `mixed: true` (and no `selected`) for a
  /// tristate in its mixed state; `checked` is unchanged. The state is read
  /// from the accessibility flags the control declares — `Semantics(checked:
  /// | toggled: | selected: | mixed:)` inside a checkbox, switch, radio,
  /// chip, tab, segment or navigation destination, or the wrapper an app
  /// puts around its own row's tap surface — by one rule shared with the new
  /// `POST /is_selected` (a `key` / `text` / `semantics` locator with `match`
  /// and `nth`): `{found, selected | mixed, control}`, or `{found: false,
  /// reason, final?}` when the locator names no control or one that
  /// declares no selection. A `ListTile`'s selected highlight is not a
  /// selection state.
  ///
  /// 1.10.0 — **typed text is a field's value, not text on screen.** A
  /// `text` locator matches only text the app draws (`Text`, `RichText`:
  /// labels, hints, rows), never what an [EditableText] holds — on every
  /// route (`/assert_visible`, `/assert_not_visible`, `/is_visible`, the
  /// waits, `/assert_text_equals|contains`, `/tap`, `/long_press`, the
  /// state routes), in the dump's `text_nth`, for `near` anchors and
  /// scroll targets, so `nth` stays one list and a value typed into a
  /// search field can neither satisfy an `expect_visible` nor block an
  /// `expect_not_visible` on the results. A field is named by its key, by
  /// the text drawn inside it (`labelText` / `hintText` / `placeholder`,
  /// still its name once faded) or by a caption beside it; `/type` and
  /// `/clear_text` no longer find a field by its value. A field's node
  /// carries `field_name` (that inner text, when it resolves back to the
  /// field alone), so a filled field keeps the locator it had when empty;
  /// `/get_text`, `/read`, `/wait_for_text`, `/find`, `/assert_exists`
  /// answer for the field when a `text` locator names it. A `text_nth`
  /// recorded against an older package can shift down by one where a
  /// field echoed a row.
  ///
  /// 1.10.1 — **a tap goes to the control the step names, or is refused.**
  /// When another control's tap handler takes the pointer before the
  /// target's own control — the opaque status-bar tap area an iOS
  /// `Scaffold` lays over the top safe area before Flutter 3.41, a
  /// translucent layer with its own `onTap` stacked in front (it wins the
  /// gesture arena) — the tap gate refuses the target as covered, naming
  /// that handler ("the status-bar tap area at the top of the screen …"),
  /// instead of reporting a tap that ran the other handler. A covered
  /// target is revealed centred, not at the leading edge it was covered at.
  /// Visibility is unchanged (seen is not tappable). No route changes.
  ///
  /// 1.11.0 — **no tap while a navigation is in progress.** Every tap-like
  /// gesture (`/tap`, `/long_press`, `/multi_tap`, `/tap_at`, a `near` tap,
  /// the focusing tap of `/type` and `/clear_text`) is refused while a route
  /// transition runs — a page push or pop, a dialog, sheet or menu opening
  /// or closing, a back-swipe — naming it (`a page transition (/checkout
  /// opening) is in progress — a tap waits for it to end`); nothing is
  /// dispatched and the engine re-tries the step. Flutter ignores pointers
  /// only on a closing route, so a tap on a page sliding in used to land
  /// mid-animation. A route in a part of the tree that is not showing (an
  /// inactive tab, an offstage overlay entry) never counts as moving, for
  /// this, `/wait_for_idle` and the dump's `animating`. `/multi_tap` passes
  /// the full tap gate (an occluded target is refused). No route changes.
  static const String protocolVersion = '1.11.0';

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
