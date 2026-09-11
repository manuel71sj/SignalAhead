import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:signalahead_mobile/prediction/prediction.dart';
import 'package:signalahead_mobile/signals/signal_stream.dart';
import 'package:signalahead_mobile/signals/signal_target.dart';

const policy = PredictionPolicy.syntheticFixture(
    maxSignalAgeMs: 5000,
    clockSkewBudgetMs: 100,
    minimumSpeedMps: 0.1,
    maxHorizontalAccuracyM: 10,
    extraSafetyMarginMs: 0);
SignalTarget target(String name, [int generation = 1]) => SignalTarget(
    sessionId: 'drive',
    targetGeneration: generation,
    provider: 'national',
    intersectionKey: 'national:$name',
    approachKey: 'national:$name:straight',
    catalogVersion: 'test-catalog');

Future<void> until(bool Function() predicate) async {
  final timeout = Stopwatch()..start();
  while (!predicate()) {
    if (timeout.elapsedMilliseconds > 4000) {
      fail('Local transport condition timed out');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

class Peer {
  Peer(this.socket, this.request);
  final WebSocket socket;
  final Map<String, dynamic> request;
  int sequence = 0;
  String epoch = 'epoch';
  void send(Map<String, Object?> snapshot, {String? requestId, int? seq}) {
    socket.add(jsonEncode({
      'type': 'snapshot',
      'requestId': requestId ?? request['requestId'],
      'streamEpoch': epoch,
      'sequence': seq ?? ++sequence,
      'snapshot': snapshot
    }));
  }
}

class FixtureServer {
  final watch = Stopwatch()..start();
  final peers = <Peer>[];
  final sockets = <WebSocket>[];
  late HttpServer server;
  int syncs = 0;
  int utcJump = 0;
  int get now => 1000000 + watch.elapsedMilliseconds;
  Uri get uri => Uri.parse('http://127.0.0.1:${server.port}');
  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      if (request.uri.path == '/v1/time') {
        syncs++;
        final received = now;
        request.response.headers.contentType = ContentType.json;
        request.response.headers.set('Cache-Control', 'no-store');
        request.response.write(jsonEncode(
            {'serverReceivedAtUtcMs': received, 'serverSentAtUtcMs': now}));
        await request.response.close();
      } else if (request.uri.path == '/v1/stream') {
        final socket = await WebSocketTransformer.upgrade(request);
        sockets.add(socket);
        socket.listen((dynamic raw) {
          final request = jsonDecode(raw as String) as Map<String, dynamic>;
          if (request['type'] == 'subscribe') peers.add(Peer(socket, request));
        });
      } else {
        request.response.statusCode = 404;
        await request.response.close();
      }
    });
  }

  SignalStreamController controller({bool synthetic = true}) =>
      SignalStreamController(
          baseUri: uri,
          policy: policy,
          monotonicNow: () => watch.elapsedMilliseconds,
          utcNow: () =>
              DateTime.fromMillisecondsSinceEpoch(now + utcJump, isUtc: true),
          syntheticFixture: synthetic);

  Map<String, Object?> snapshot(String name,
      {int? stamp, int lifetime = 3000, String state = 'green'}) {
    final observed = stamp ?? now;
    return {
      'schemaVersion': 'sa-contract-1',
      'kind': 'SignalObservation',
      'provider': 'national',
      'intersectionKey': 'national:$name',
      'approachKey': 'national:$name:straight',
      'movement': 'straight',
      'signalState': state,
      'catalogVersion': 'test-catalog',
      'sourceRevision': 'synthetic-test',
      'sourceIntersectionId': name,
      'sourceEventId': null,
      'sourceObservedAtUtcMs': observed,
      'sourceTimeKind': 'generated',
      'serverReceivedAtUtcMs': observed,
      'serverSentAtUtcMs': observed,
      'remainingAtSourceMs': lifetime,
      'expiresAtUtcMs': observed + lifetime,
      'timingQuality': 'verified',
      'unitEvidence': {
        'sourceField': 'fixture',
        'sourceUnit': 'ms',
        'conversion': 'identity',
        'evidence': 'synthetic only'
      },
      'rawStateCode': null
    };
  }

  Future<void> close() async {
    for (final socket in sockets) {
      unawaited(socket.close());
    }
    await server.close(force: true);
  }
}

void main() {
  late FixtureServer server;
  late SignalStreamController controller;
  setUp(() async {
    server = FixtureServer();
    await server.start();
    controller = server.controller();
  });
  tearDown(() async {
    controller.dispose();
    await server.close();
  });

  test('A to B clears immediately and ignores late A request and socket',
      () async {
    await controller.selectTarget(target('A'));
    await until(() => server.peers.length == 1);
    final a = server.peers[0];
    a.send(server.snapshot('A'));
    await until(() => controller.reading != null);
    final switching = controller.selectTarget(target('B', 2));
    expect(controller.reading, isNull);
    a.send(server.snapshot('A'));
    await switching;
    await until(() => server.peers.length == 2);
    final b = server.peers[1];
    b.send(server.snapshot('A'), requestId: a.request['requestId'] as String);
    b.send(server.snapshot('B', state: 'red'));
    await until(() => controller.reading?.signalState == SignalState.red);
    expect(controller.reading!.sourceEventKey, contains('national:B'));
  });

  test('disconnect synchronizes again but replay cannot restore old possible',
      () async {
    await controller.selectTarget(target('A'));
    await until(() => server.peers.length == 1);
    final original = server.snapshot('A');
    server.peers[0].send(original);
    await until(() => controller.reading != null);
    await server.peers[0].socket.close();
    await until(() => !controller.isConnected);
    expect(controller.reading, isNull);
    await until(() => server.peers.length == 2);
    expect(server.syncs, 2);
    final peer = server.peers[1]..epoch = 'new-epoch';
    peer.send(original);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(controller.reading, isNull);
    peer.send(server.snapshot('A', state: 'yellow'));
    await until(() => controller.reading?.signalState == SignalState.yellow);
    // New transport order is never newer source order.
    peer.send(original);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(controller.reading!.signalState, SignalState.yellow);
  });

  test(
      'duplicate receipt never extends expiry and expiry notifies without traffic',
      () async {
    await controller.selectTarget(target('A'));
    await until(() => server.peers.isNotEmpty);
    final packet = server.snapshot('A', lifetime: 350);
    server.peers[0].send(packet);
    await until(() => controller.reading != null);
    var expiredNotification = false;
    controller.addListener(() {
      if (controller.reading == null) expiredNotification = true;
    });
    await Future<void>.delayed(const Duration(milliseconds: 100));
    server.peers[0].send(packet);
    await until(() => expiredNotification);
    expect(controller.reading, isNull);
    server.peers[0].send(packet);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(controller.reading, isNull);
  });

  test(
      'reused provider event ID cannot re-anchor even with a greater timestamp',
      () async {
    await controller.selectTarget(target('A'));
    await until(() => server.peers.isNotEmpty);
    final peer = server.peers[0];
    peer.send(
        {...server.snapshot('A', lifetime: 300), 'sourceEventId': 'event-1'});
    await until(() => controller.reading != null);
    final originalSourceTime = controller.reading!.sourceObservedAtUtcMs;
    await Future<void>.delayed(const Duration(milliseconds: 50));
    peer.send({...server.snapshot('A'), 'sourceEventId': 'event-1'});
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(controller.reading!.sourceObservedAtUtcMs, originalSourceTime);
    await until(() => controller.reading == null);
    peer.send({...server.snapshot('A'), 'sourceEventId': 'event-1'});
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(controller.reading, isNull);
    peer.send(
        {...server.snapshot('A', state: 'red'), 'sourceEventId': 'event-2'});
    await until(() => controller.reading?.signalState == SignalState.red);
  });

  test('epoch changes and non-increasing sequence invalidate the connection',
      () async {
    await controller.selectTarget(target('A'));
    await until(() => server.peers.isNotEmpty);
    server.peers[0].send(server.snapshot('A'));
    await until(() => controller.reading != null);
    server.peers[0].send(server.snapshot('A'), seq: 1);
    await until(() => !controller.isConnected);
    expect(controller.reading, isNull);
    await until(() => server.peers.length == 2);
    final peer = server.peers[1];
    peer.send(server.snapshot('A'));
    await until(() => controller.reading != null);
    peer.epoch = 'impossible-same-connection-change';
    peer.send(server.snapshot('A'));
    await until(() => !controller.isConnected);
    expect(controller.reading, isNull);
  });

  test('wrong canonical identity and noninteger duration fail closed',
      () async {
    await controller.selectTarget(target('A'));
    await until(() => server.peers.isNotEmpty);
    server.peers[0].send(server.snapshot('B'));
    await until(() => !controller.isConnected);
    expect(controller.reading, isNull);
    await until(() => server.peers.length == 2);
    server.peers[1]
        .send({...server.snapshot('A'), 'remainingAtSourceMs': 1000.5});
    await until(() => !controller.isConnected);
    expect(controller.reading, isNull);
  });

  test('unknown timing clears, and clock jumps clear even with no packets',
      () async {
    await controller.selectTarget(target('A'));
    await until(() => server.peers.isNotEmpty);
    final peer = server.peers[0];
    peer.send(server.snapshot('A', state: 'flashing'));
    await until(() => controller.reading?.signalState == SignalState.flashing);
    peer.send({...server.snapshot('A'), 'timingQuality': 'unverified'});
    await until(() => controller.reading == null);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    peer.send(server.snapshot('A'));
    await until(() => controller.reading != null);
    server.utcJump = 1000;
    expect(controller.reading, isNull); // getter before the monitoring timer
    await until(() => !controller.isConnected);
  });

  test(
      'background, stop and dispose cancel reconnect and suppress late completion',
      () async {
    await controller.selectTarget(target('A'));
    await until(() => server.peers.isNotEmpty);
    server.peers[0].send(server.snapshot('A'));
    await until(() => controller.reading != null);
    controller.setForeground(false);
    expect(controller.reading, isNull);
    expect(controller.isConnected, isFalse);
    await Future<void>.delayed(const Duration(milliseconds: 350));
    expect(server.peers.length, 1);
    controller.setForeground(true);
    await until(() => server.peers.length == 2);
    await controller.selectTarget(null);
    await Future<void>.delayed(const Duration(milliseconds: 350));
    expect(server.peers.length, 2);
    final connecting = controller.selectTarget(target('B', 3));
    controller.dispose();
    await connecting;
    final count = server.peers.length;
    await Future<void>.delayed(const Duration(milliseconds: 350));
    expect(controller.reading, isNull);
    expect(controller.isConnected, isFalse);
    expect(server.peers.length, count);
  });

  test('synthetic policy cannot authorize a normal operational caller',
      () async {
    controller.dispose();
    controller = server.controller(synthetic: false);
    await controller.selectTarget(target('A'));
    expect(controller.reading, isNull);
    expect(controller.isConnected, isFalse);
    expect(server.syncs, 0);
  });
}
