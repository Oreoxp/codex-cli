import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:xiao_pangxie_workbench/models/chat_message.dart';
import 'package:xiao_pangxie_workbench/models/protocol.dart';
import 'package:xiao_pangxie_workbench/controllers/workbench_controller.dart';
import 'package:xiao_pangxie_workbench/services/app_server_service.dart';

/// Fake [AppServerService] — no real WS needed.
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

  void inject(AppServerMessage msg) => _fakeMessages.add(msg);

  @override
  Future<void> connect(String url) async {
    _fakeConnected = true;
  }

  @override
  Future<void> disconnect() async {
    _fakeConnected = false;
  }

  @override
  Future<dynamic> sendRequest(String method, Map<String, dynamic> params) async {
    sentRequests.add({'method': method, 'params': params});
    if (method == 'thread/start') return {'thread': {'id': 'thr_fake'}};
    if (method == 'turn/start') return {'turn': {'id': 'turn_fake', 'status': 'inProgress'}};
    return {};
  }

  @override
  void sendResponse(dynamic requestId, Map<String, dynamic> result) {
    sentResponses.add({'id': requestId, 'result': result});
  }
}

/// Fake service that refuses to connect.
class FailingAppServerService extends AppServerService {
  final StreamController<AppServerMessage> _sc =
      StreamController.broadcast(sync: true);

  @override
  Stream<AppServerMessage> get messages => _sc.stream;

  @override
  bool get isConnected => false;

  @override
  AppServerConnectionState get state => AppServerConnectionState.error;

  @override
  Future<void> connect(String url) async =>
      throw Exception('simulated connection failure: server not reachable at $url');

  @override
  Future<void> disconnect() async {}

  @override
  Future<dynamic> sendRequest(String method, Map<String, dynamic> params) async => {};

  @override
  void sendResponse(dynamic requestId, Map<String, dynamic> result) {}
}

void main() {
  late FakeAppServerService fakeService;
  late WorkbenchController controller;

  setUp(() {
    fakeService = FakeAppServerService();
    controller = WorkbenchController(fakeService);
  });

  tearDown(() => controller.dispose());

  // ── Connection ─────────────────────────────────────────────────────────────

  group('connection', () {
    test('connect sets isConnected', () async {
      await controller.connect('ws://127.0.0.1:9999');
      expect(controller.isConnected, isTrue);
    });

    test('disconnect clears thread state', () async {
      await controller.connect('ws://localhost:9999');
      controller.currentThreadId = 'some_thread';
      await controller.disconnect();
      expect(controller.isConnected, isFalse);
      expect(controller.currentThreadId, isNull);
      expect(controller.currentTurnStatus, isNull);
    });

    test('connect failure does not throw — controller stays stable', () async {
      final ctrl = WorkbenchController(FailingAppServerService());
      // Must not throw; controller swallows and logs.
      await expectLater(ctrl.connect('ws://bad:9999'), completes);
      expect(ctrl.isConnected, isFalse);
      ctrl.dispose();
    });
  });

  // ── Turn lifecycle ─────────────────────────────────────────────────────────

  group('startTurn', () {
    setUp(() async => controller.connect('ws://localhost:9999'));

    test('opens thread then starts turn', () async {
      await controller.startTurn('Run tests', cwd: '/repo');
      expect(controller.currentThreadId, 'thr_fake');
      expect(controller.currentTurnId, 'turn_fake');
      expect(controller.currentTurnStatus, 'inProgress');
    });

    test('reuses existing thread', () async {
      controller.currentThreadId = 'thr_existing';
      await controller.startTurn('Fix bug');
      final threadCalls =
          fakeService.sentRequests.where((r) => r['method'] == 'thread/start');
      expect(threadCalls.isEmpty, isTrue);
    });

    test('ignored when disconnected', () async {
      await controller.disconnect();
      await controller.startTurn('ignored');
      expect(controller.currentThreadId, isNull);
    });
  });

  // ── Notifications ──────────────────────────────────────────────────────────

  group('notification handling', () {
    setUp(() async => controller.connect('ws://localhost:9999'));

    test('turn/started sets status inProgress', () {
      fakeService.inject(AppServerNotification(
        method: 'turn/started',
        params: {'turn': {'id': 'turn_1'}, 'threadId': 'th1'},
      ));
      expect(controller.currentTurnStatus, 'inProgress');
    });

    test('turn/completed sets status', () {
      fakeService.inject(AppServerNotification(
        method: 'turn/completed',
        params: {'turn': {'id': 'turn_1', 'status': 'completed'}},
      ));
      expect(controller.currentTurnStatus, 'completed');
    });

    test('turn/diff/updated stores diff', () {
      fakeService.inject(AppServerNotification(
        method: 'turn/diff/updated',
        params: {'diff': '+added\n-removed'},
      ));
      expect(controller.lastTurnDiff, '+added\n-removed');
    });
  });

  // ── Chat messages ──────────────────────────────────────────────────────────

  group('chatMessages', () {
    setUp(() async => controller.connect('ws://localhost:9999'));

    test('startTurn adds user message', () async {
      await controller.startTurn('Hello', cwd: '/tmp');
      expect(controller.chatMessages.length, 1);
      expect(controller.chatMessages.first.role, ChatRole.user);
      expect(controller.chatMessages.first.text, 'Hello');
    });

    test('turn/completed flushes assistant message', () async {
      await controller.startTurn('Hi', cwd: '/tmp');
      fakeService.inject(AppServerNotification(
        method: 'item/agentMessage/delta',
        params: {'itemId': 'i1', 'delta': 'Hi there!'},
      ));
      fakeService.inject(AppServerNotification(
        method: 'turn/completed',
        params: {'turn': {'id': 'turn_1', 'status': 'completed'}},
      ));
      expect(controller.chatMessages.length, 2);
      expect(controller.chatMessages[1].role, ChatRole.assistant);
      expect(controller.chatMessages[1].text, 'Hi there!');
    });

    test('streamingText accumulates deltas mid-turn', () {
      fakeService.inject(AppServerNotification(
        method: 'item/agentMessage/delta',
        params: {'itemId': 'i1', 'delta': 'Part1 '},
      ));
      fakeService.inject(AppServerNotification(
        method: 'item/agentMessage/delta',
        params: {'itemId': 'i1', 'delta': 'Part2'},
      ));
      expect(controller.streamingText, 'Part1 Part2');
    });

    test('deltas across items restart buffer', () {
      fakeService.inject(AppServerNotification(
        method: 'item/agentMessage/delta',
        params: {'itemId': 'i1', 'delta': 'First '},
      ));
      fakeService.inject(AppServerNotification(
        method: 'item/agentMessage/delta',
        params: {'itemId': 'i2', 'delta': 'Second'},
      ));
      expect(controller.streamingText, 'Second');
    });

    test('multi-turn: each turn appends both messages', () async {
      await controller.startTurn('Turn1', cwd: '/');
      fakeService.inject(AppServerNotification(
        method: 'item/agentMessage/delta',
        params: {'itemId': 'i1', 'delta': 'Reply1'},
      ));
      fakeService.inject(AppServerNotification(
        method: 'turn/completed',
        params: {'turn': {'id': 't1', 'status': 'completed'}},
      ));

      await controller.startTurn('Turn2', cwd: '/');
      fakeService.inject(AppServerNotification(
        method: 'item/agentMessage/delta',
        params: {'itemId': 'i2', 'delta': 'Reply2'},
      ));
      fakeService.inject(AppServerNotification(
        method: 'turn/completed',
        params: {'turn': {'id': 't2', 'status': 'completed'}},
      ));

      expect(controller.chatMessages.length, 4);
      expect(controller.chatMessages[0].text, 'Turn1');
      expect(controller.chatMessages[1].text, 'Reply1');
      expect(controller.chatMessages[2].text, 'Turn2');
      expect(controller.chatMessages[3].text, 'Reply2');
    });
  });

  // ── Approval ───────────────────────────────────────────────────────────────

  group('approval', () {
    setUp(() async => controller.connect('ws://localhost:9999'));

    test('command approval request sets pendingApproval', () {
      fakeService.inject(AppServerServerRequest(
        id: 99,
        method: 'item/commandExecution/requestApproval',
        params: {
          'threadId': 'th1',
          'turnId': 'tu1',
          'command': ['rm', '-rf', '/tmp/test'],
          'cwd': '/repo',
          'reason': 'cleanup temp files',
        },
      ));
      expect(controller.pendingApproval, isNotNull);
      expect(controller.pendingApproval!.requestId, 99);
      expect(controller.pendingApproval!.command, ['rm', '-rf', '/tmp/test']);
      expect(controller.pendingApproval!.reason, 'cleanup temp files');
    });

    test('respondToApproval sends response and clears pending', () {
      fakeService.inject(AppServerServerRequest(
        id: 77,
        method: 'item/commandExecution/requestApproval',
        params: {'threadId': 'th1', 'turnId': 'tu1'},
      ));
      controller.respondToApproval('accept');
      expect(controller.pendingApproval, isNull);
      expect(fakeService.sentResponses.first['result'], {'decision': 'accept'});
    });

    test('fileChange approval sets correct kind', () {
      fakeService.inject(AppServerServerRequest(
        id: 55,
        method: 'item/fileChange/requestApproval',
        params: {'threadId': 'th1', 'turnId': 'tu1'},
      ));
      expect(controller.pendingApproval!.kind, 'fileChange');
    });
  });
}
