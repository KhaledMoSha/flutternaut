import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:flutternaut/flutternaut.dart';
import 'package:flutternaut/src/bridge/bridge_port.dart';
import 'package:flutternaut/src/bridge/engine/main_thread_runner.dart';
import 'package:flutternaut/src/bridge/engine/tree_walker.dart';
import 'package:flutternaut/src/bridge/handlers/health_handler.dart';
import 'package:flutternaut/src/bridge/process_environment.dart';
import 'package:flutternaut/src/bridge/router.dart';
import 'package:flutternaut/src/bridge/server.dart';

/// A fake process environment: only what the test puts in it.
EnvironmentReader _env([Map<String, String> values = const {}]) =>
    (name) => values[name];

class _RealHttpOverrides extends HttpOverrides {}

/// GET [path] on 127.0.0.1:[port] with a real socket (flutter_test replaces
/// HttpClient with a stub that never reaches one).
Future<(int, Map<String, dynamic>)> _get(int port, String path) {
  return HttpOverrides.runZoned(
    () async {
      final client = HttpClient();
      try {
        final request = await client
            .open('GET', InternetAddress.loopbackIPv4.address, port, path)
            .timeout(const Duration(seconds: 5));
        final response =
            await request.close().timeout(const Duration(seconds: 5));
        final text = await utf8.decoder
            .bind(response)
            .join()
            .timeout(const Duration(seconds: 5));
        return (response.statusCode, jsonDecode(text) as Map<String, dynamic>);
      } finally {
        client.close(force: true);
      }
    },
    createHttpClient: (context) =>
        _RealHttpOverrides().createHttpClient(context),
  );
}

/// A port nothing is listening on right now.
Future<int> _freePort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}

BridgeServer _server(EnvironmentReader environment) => BridgeServer(
      log: (_) {},
      environment: environment,
      address: InternetAddress.loopbackIPv4,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('resolveBridgePort', () {
    test('no variable, no argument: the default port', () {
      final chosen = resolveBridgePort(argument: null, environment: _env());
      expect(chosen.port, 8500);
      expect(chosen.source, BridgePortSource.defaultPort);
      expect(FlutternautBridge.defaultPort, 8500);
    });

    test('no variable: the argument', () {
      final chosen = resolveBridgePort(argument: 9100, environment: _env());
      expect(chosen.port, 9100);
      expect(chosen.source, BridgePortSource.argument);
    });

    test('the variable alone chooses the port', () {
      final chosen = resolveBridgePort(
        argument: null,
        environment: _env({'FLUTTERNAUT_BRIDGE_PORT': '8611'}),
      );
      expect(chosen.port, 8611);
      expect(chosen.source, BridgePortSource.environment);
    });

    test('the variable beats the argument', () {
      final chosen = resolveBridgePort(
        argument: 9100,
        environment: _env({'FLUTTERNAUT_BRIDGE_PORT': '8611'}),
      );
      expect(chosen.port, 8611);
      expect(chosen.source, BridgePortSource.environment);
    });

    test('the edges of the TCP range are ports', () {
      for (final value in ['1', '65535']) {
        final chosen = resolveBridgePort(
          argument: null,
          environment: _env({'FLUTTERNAUT_BRIDGE_PORT': value}),
        );
        expect(chosen.port, int.parse(value));
      }
    });

    for (final value in [
      '',
      'abc',
      '0',
      '-1',
      '65536',
      '99999999999999999999999',
      '8611.0',
      '0x2000',
      '+8611',
      ' 8611',
      '8611 ',
      '86 11',
    ]) {
      test('"$value" is not a port: throws, never falls back', () {
        for (final argument in [null, 9100]) {
          expect(
            () => resolveBridgePort(
              argument: argument,
              environment: _env({'FLUTTERNAUT_BRIDGE_PORT': value}),
            ),
            throwsA(
              isA<FlutternautBridgeException>().having(
                (e) => e.message,
                'message',
                allOf(
                  contains('FLUTTERNAUT_BRIDGE_PORT'),
                  contains('is set to "$value"'),
                  contains('not a TCP port'),
                  contains('does not fall back to ${argument ?? 8500}'),
                ),
              ),
            ),
          );
        }
      });
    }

    test('only the port variable is consulted', () {
      final asked = <String>[];
      resolveBridgePort(
        argument: null,
        environment: (name) {
          asked.add(name);
          return null;
        },
      );
      expect(asked, ['FLUTTERNAUT_BRIDGE_PORT']);
    });
  });

  group('readSimulatorUdid', () {
    test('present', () {
      expect(
        readSimulatorUdid(_env({'SIMULATOR_UDID': 'ABCD-1234'})),
        'ABCD-1234',
      );
    });

    test('absent or empty is no device id', () {
      expect(readSimulatorUdid(_env()), isNull);
      expect(readSimulatorUdid(_env({'SIMULATOR_UDID': ''})), isNull);
    });
  });

  group('/health', () {
    test('carries the bound port and the simulator UDID', () async {
      final server = _server(_env({'SIMULATOR_UDID': 'ABCD-1234'}));
      addTearDown(server.stop);
      await server.start(const BridgePort(0, BridgePortSource.argument));
      final bound = server.port;
      expect(bound, isNotNull);
      expect(bound, greaterThan(0));

      final (status, body) = await _get(bound!, '/health');

      expect(status, 200);
      expect(body['success'], isTrue);
      final data = body['data'] as Map<String, dynamic>;
      expect(data['port'], bound);
      expect(data['device_id'], 'ABCD-1234');
    });

    test(
        'without SIMULATOR_UDID there is no device_id, and nothing else '
        'changed', () async {
      final server = _server(_env());
      addTearDown(server.stop);
      await server.start(const BridgePort(0, BridgePortSource.argument));

      final (status, body) = await _get(server.port!, '/health');

      expect(status, 200);
      final data = body['data'] as Map<String, dynamic>;
      expect(data.containsKey('device_id'), isFalse);
      // `app` is present only where the platform names the app (not under
      // flutter_tester); every other field is always there.
      expect(
        data.keys.toSet()..remove('app'),
        {
          'status',
          'bridge',
          'protocol_version',
          'instance_id',
          'port',
          'first_frame',
        },
      );
      expect(data['status'], 'ok');
      expect(data['bridge'], 'flutternaut');
      expect(data['protocol_version'], '1.5.1');
      expect(data['instance_id'], matches(RegExp(r'^[0-9a-f]{16}$')));
      expect(data['port'], server.port);
      expect(data['first_frame'], isA<bool>());
    });

    test('an empty SIMULATOR_UDID is no device_id', () async {
      final server = _server(_env({'SIMULATOR_UDID': ''}));
      addTearDown(server.stop);
      await server.start(const BridgePort(0, BridgePortSource.argument));

      final (_, body) = await _get(server.port!, '/health');

      expect(
        (body['data'] as Map<String, dynamic>).containsKey('device_id'),
        isFalse,
      );
    });

    test('a handler whose server is not bound answers 500, not a made-up port',
        () async {
      final router = BridgeRouter(log: (_) {});
      HealthHandler(
        walker: TreeWalker(),
        runner: MainThreadRunner(),
        boundPort: () => null,
        environment: _env(),
      ).register(router);
      final socket = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => socket.close(force: true));
      socket.listen(router.handle);

      final (status, body) = await _get(socket.port, '/health');

      expect(status, 500);
      expect(body['success'], isFalse);
      expect(body['error'], contains('not bound'));
    });
  });

  group('a port that is already in use', () {
    late ServerSocket holder;

    setUp(() async {
      holder = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    });

    tearDown(() => holder.close());

    Future<FlutternautBridgeException> startOn(BridgePortSource source) async {
      final logged = <String>[];
      final server = BridgeServer(
        log: logged.add,
        environment: _env(),
        address: InternetAddress.loopbackIPv4,
      );
      addTearDown(server.stop);
      try {
        await server.start(BridgePort(holder.port, source));
      } on FlutternautBridgeException catch (e) {
        expect(server.isRunning, isFalse);
        expect(server.port, isNull);
        expect(logged.single, contains(e.message));
        expect(e.cause, isA<SocketException>());
        return e;
      }
      fail('binding the held port ${holder.port} succeeded');
    }

    test('from the environment: names the port and the variable', () async {
      final e = await startOn(BridgePortSource.environment);
      expect(
        e.message,
        allOf(
          contains('could not bind port ${holder.port}'),
          contains('from the FLUTTERNAUT_BRIDGE_PORT environment variable'),
          contains('relaunch the app'),
          isNot(contains('simulators share')),
        ),
      );
    });

    test('from the argument: names the port and the argument', () async {
      final e = await startOn(BridgePortSource.argument);
      expect(
        e.message,
        allOf(
          contains('could not bind port ${holder.port}'),
          contains('from the port: argument of '
              'FlutternautBridge.ensureInitialized'),
          isNot(contains('simulators share')),
        ),
      );
    });

    test('the default: says another app probably holds it', () async {
      final e = await startOn(BridgePortSource.defaultPort);
      expect(
        e.message,
        allOf(
          contains('could not bind port ${holder.port}'),
          contains('the default port'),
          contains('Another app is probably already serving the bridge'),
          contains("iOS simulators share the Mac's network stack"),
          contains('FLUTTERNAUT_BRIDGE_PORT'),
        ),
      );
      expect(e.toString(), startsWith('FlutternautBridgeException: '));
    });
  });

  group('FlutternautBridge.start', () {
    tearDown(FlutternautBridge.dispose);

    test('binds the port the environment names, over the argument', () async {
      final fromEnvironment = await _freePort();
      final fromArgument = await _freePort();

      await FlutternautBridge.start(
        port: fromArgument,
        environment: _env({
          'FLUTTERNAUT_BRIDGE_PORT': '$fromEnvironment',
          'SIMULATOR_UDID': 'SIM-1',
        }),
      );

      expect(FlutternautBridge.instance.isRunning, isTrue);
      expect(FlutternautBridge.instance.port, fromEnvironment);
      final (status, body) = await _get(fromEnvironment, '/health');
      expect(status, 200);
      final data = body['data'] as Map<String, dynamic>;
      expect(data['port'], fromEnvironment);
      expect(data['device_id'], 'SIM-1');
      // Nothing listens on the argument's port.
      final probe =
          await ServerSocket.bind(InternetAddress.loopbackIPv4, fromArgument);
      await probe.close();
    });

    test('without the variable binds the argument', () async {
      final fromArgument = await _freePort();

      await FlutternautBridge.start(port: fromArgument, environment: _env());

      expect(FlutternautBridge.instance.port, fromArgument);
      final (_, body) = await _get(fromArgument, '/health');
      final data = body['data'] as Map<String, dynamic>;
      expect(data['port'], fromArgument);
      expect(data.containsKey('device_id'), isFalse);
    });

    test('an invalid variable throws and leaves the bridge stopped', () async {
      final fromArgument = await _freePort();

      await expectLater(
        FlutternautBridge.start(
          port: fromArgument,
          environment: _env({'FLUTTERNAUT_BRIDGE_PORT': 'abc'}),
        ),
        throwsA(
          isA<FlutternautBridgeException>().having(
            (e) => e.message,
            'message',
            allOf(contains('FLUTTERNAUT_BRIDGE_PORT'), contains('"abc"')),
          ),
        ),
      );

      expect(FlutternautBridge.instance.isRunning, isFalse);
      expect(FlutternautBridge.instance.port, isNull);
      // It did not quietly bind the argument's port instead.
      final probe =
          await ServerSocket.bind(InternetAddress.loopbackIPv4, fromArgument);
      await probe.close();
    });

    test(
        'a port in use throws, leaves the bridge stopped, and a later call '
        'can start it', () async {
      final holder = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final held = holder.port;
      final environment = _env({'FLUTTERNAUT_BRIDGE_PORT': '$held'});

      try {
        await expectLater(
          FlutternautBridge.start(environment: environment),
          throwsA(
            isA<FlutternautBridgeException>().having(
              (e) => e.message,
              'message',
              allOf(
                contains('could not bind port $held'),
                contains('FLUTTERNAUT_BRIDGE_PORT'),
              ),
            ),
          ),
        );
        expect(FlutternautBridge.instance.isRunning, isFalse);
      } finally {
        await holder.close();
      }

      await FlutternautBridge.start(environment: environment);
      expect(FlutternautBridge.instance.port, held);
    });

    test('listens on the loopback interface unless told otherwise', () async {
      await FlutternautBridge.start(port: await _freePort(), environment: _env());

      expect(FlutternautBridge.instance.address, InternetAddress.loopbackIPv4);
    });

    test('bindAddress opts in to another interface', () async {
      await FlutternautBridge.start(
        port: await _freePort(),
        bindAddress: InternetAddress.anyIPv4,
        environment: _env(),
      );

      expect(FlutternautBridge.instance.address, InternetAddress.anyIPv4);
    });

    test('disabled: nothing starts and the environment is not read', () async {
      await FlutternautBridge.start(
        enabled: false,
        environment: (name) => fail('read $name while disabled'),
      );
      expect(FlutternautBridge.instance.isRunning, isFalse);
    });

    test('already running: a second call is ignored', () async {
      final first = await _freePort();
      await FlutternautBridge.start(port: first, environment: _env());

      await FlutternautBridge.start(
        environment: _env({'FLUTTERNAUT_BRIDGE_PORT': 'abc'}),
      );

      expect(FlutternautBridge.instance.port, first);
    });
  });

  group('bind failures', () {
    test(
        'permission denied names the Android INTERNET permission, not '
        'another app on the port', () {
      final message = BridgeServer.bindFailure(
        resolveBridgePort(argument: null, environment: _env()),
        const SocketException(
          'Failed to create server socket',
          osError: OSError('Permission denied', 13),
        ),
      );

      expect(message, contains('could not bind port 8500'));
      expect(message, contains('android.permission.INTERNET'));
      expect(message, contains('src/main/AndroidManifest.xml'));
      expect(message, isNot(contains('Another app')));
    });

    test('an address in use on the default port still points at another app',
        () {
      final message = BridgeServer.bindFailure(
        resolveBridgePort(argument: null, environment: _env()),
        const SocketException(
          'Failed to create server socket',
          osError: OSError('Address already in use', 48),
        ),
      );

      expect(message, contains('Another app'));
      expect(message, isNot(contains('INTERNET')));
    });
  });
}
