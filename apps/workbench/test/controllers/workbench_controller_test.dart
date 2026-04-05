import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:xiao_pangxie_workbench/models/event_entry.dart';
import 'package:xiao_pangxie_workbench/models/protocol.dart';
import 'package:xiao_pangxie_workbench/controllers/workbench_controller.dart';
import 'package:xiao_pangxie_workbench/services/app_server_service.dart';

/// Fake [AppServerService] that exposes a sink for injecting messages
/// and records sent JSON payloads.
class FakeAppServerService extends AppServerService {
  final StreamController<AppServerMessage> _fakeMessages =
      StreamController.broadcast(sync: true);

  @override
  Stream<AppServerMessage> get messages => _fakeMessages.stream;

  @override
  bool get isConnected => _fakeConnected;
  bool _fakeConnected = false;

  final List<Map<String, dynamic>> sentResponses = [];
  final List<Map<String, dynamic>> sentRequests = [];

  /// Inject a message into the stream as if it came from the server.
  void inject(AppServerMessage msg) => _fakeMessages.add(msg);

  @override
  Future<void> connect(String url) async {
    _fakeConnected = true;
  }

  @override
  Future<void> disconnect() async {
    _fakeConnected = false;
  }

  // Simulate a successful thread/start result.
  @override
  Future<dynamic> sendRequest(String method, Map<String, dynamic> params) async {
    sentRequests.add({'method': method, 'params': params});
    if (method == 'thread/start') {
      return {'thread': {'id': 'thr_fake'}};
    }
    if (method == 'turn/start') {
      return {'turn': {'id': 'turn_fake', 'status': 'inProgress'}};
    }
    return {};
  }

  @override
  void sendResponse(dynamic requestId, Map<String, dynamic> result) {
    sentResponses.add({'id': requestId, 'result': result});
  }
}

void main() {
  late FakeAppServerService fakeService;
  late WorkbenchController controller;

  setUp(() {
    fakeService = FakeAppServerService();
    controller = WorkbenchController(fakeService, userProfile: null);
  });

  tearDown(() {
    controller.dispose();
  });

  group('WorkbenchController connection', () {
    test('connect sets up message listener', () async {
      await controller.connect('ws://127.0.0.1:9999');
      expect(controller.isConnected, isTrue);
      expect(
        controller.events.any((e) => e.kind == EventKind.connected),
        isTrue,
      );
    });

    test('disconnect clears state', () async {
      await controller.connect('ws://localhost:9999');
      controller.currentThreadId = 'some_thread';
      await controller.disconnect();
      expect(controller.currentThreadId, isNull);
      expect(controller.events.any((e) => e.kind == EventKind.disconnected), isTrue);
    });
  });

  group('WorkbenchController startTurn', () {
    setUp(() async {
      await controller.connect('ws://localhost:9999');
    });

    test('startTurn opens thread then starts turn', () async {
      await controller.startTurn('Run tests', cwd: '/repo');
      expect(controller.currentThreadId, 'thr_fake');
      expect(controller.currentTurnId, 'turn_fake');
      expect(controller.currentTurnStatus, 'inProgress');
    });

    test('startTurn reuses existing thread', () async {
      controller.currentThreadId = 'thr_existing';
      await controller.startTurn('Fix bug');
      // Should NOT call thread/start again
      final threadStartCalls = fakeService.sentRequests
          .where((r) => r['method'] == 'thread/start');
      expect(threadStartCalls.isEmpty, isTrue);
    });
  });

  group('WorkbenchController notification handling', () {
    setUp(() async {
      await controller.connect('ws://localhost:9999');
    });

    test('turn/started notification adds event', () {
      fakeService.inject(AppServerNotification(
        method: 'turn/started',
        params: {'turn': {'id': 'turn_1'}},
      ));
      expect(
        controller.events.any((e) => e.kind == EventKind.turnStarted),
        isTrue,
      );
    });

    test('turn/completed sets status', () {
      fakeService.inject(AppServerNotification(
        method: 'turn/completed',
        params: {'turn': {'id': 'turn_1', 'status': 'completed'}},
      ));
      expect(controller.currentTurnStatus, 'completed');
    });

    test('item/started notification appears in feed', () {
      fakeService.inject(AppServerNotification(
        method: 'item/started',
        params: {
          'item': {'type': 'commandExecution', 'command': ['ls']}
        },
      ));
      expect(
        controller.events.any((e) => e.kind == EventKind.itemStarted),
        isTrue,
      );
    });
  });

  group('WorkbenchController approval', () {
    setUp(() async {
      await controller.connect('ws://localhost:9999');
    });

    test('server approval request sets pendingApproval', () {
      fakeService.inject(AppServerServerRequest(
        id: 99,
        method: 'item/commandExecution/requestApproval',
        params: {
          'threadId': 'th1',
          'turnId': 'tu1',
          'command': ['rm', '-rf', '/tmp/test'],
          'cwd': '/repo',
        },
      ));
      expect(controller.pendingApproval, isNotNull);
      expect(controller.pendingApproval!.requestId, 99);
      expect(controller.pendingApproval!.command, ['rm', '-rf', '/tmp/test']);
    });

    test('respondToApproval sends response and clears pending', () {
      fakeService.inject(AppServerServerRequest(
        id: 77,
        method: 'item/commandExecution/requestApproval',
        params: {'threadId': 'th1', 'turnId': 'tu1'},
      ));
      expect(controller.pendingApproval, isNotNull);

      controller.respondToApproval('accept');

      expect(controller.pendingApproval, isNull);
      expect(fakeService.sentResponses.length, 1);
      expect(fakeService.sentResponses.first['result'], {'decision': 'accept'});
    });

    test('file change approval request sets correct kind', () {
      fakeService.inject(AppServerServerRequest(
        id: 55,
        method: 'item/fileChange/requestApproval',
        params: {'threadId': 'th1', 'turnId': 'tu1'},
      ));
      expect(controller.pendingApproval!.kind, 'fileChange');
    });
  });

  group('WorkbenchController agent message delta', () {
    setUp(() async {
      await controller.connect('ws://localhost:9999');
    });

    test('agentMessage deltas are accumulated in buffer', () {
      fakeService.inject(AppServerNotification(
        method: 'item/agentMessage/delta',
        params: {'itemId': 'item_1', 'delta': 'Hello '},
      ));
      fakeService.inject(AppServerNotification(
        method: 'item/agentMessage/delta',
        params: {'itemId': 'item_1', 'delta': 'world!'},
      ));
      // Simulate turn completed to flush the buffer.
      fakeService.inject(AppServerNotification(
        method: 'turn/completed',
        params: {'turn': {'id': 'turn_1', 'status': 'completed'}},
      ));
      expect(controller.lastAgentMessage, 'Hello world!');
    });
  });
}
