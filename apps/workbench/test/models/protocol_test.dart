import 'package:flutter_test/flutter_test.dart';
import 'package:xiao_pangxie_workbench/models/protocol.dart';

void main() {
  group('parseAppServerMessage', () {
    test('parses notification (no id)', () {
      const raw = '{"method":"turn/started","params":{"turn":{"id":"t1"}}}';
      final msg = parseAppServerMessage(raw);
      expect(msg, isA<AppServerNotification>());
      final n = msg as AppServerNotification;
      expect(n.method, 'turn/started');
      expect(n.params!['turn']['id'], 't1');
    });

    test('parses server-initiated request (has id + method)', () {
      const raw =
          '{"id":42,"method":"item/commandExecution/requestApproval",'
          '"params":{"threadId":"th1","turnId":"tu1","command":["ls","-la"]}}';
      final msg = parseAppServerMessage(raw);
      expect(msg, isA<AppServerServerRequest>());
      final r = msg as AppServerServerRequest;
      expect(r.id, 42);
      expect(r.method, 'item/commandExecution/requestApproval');
      expect(r.params!['command'], ['ls', '-la']);
    });

    test('parses successful response', () {
      const raw = '{"id":1,"result":{"thread":{"id":"thr_abc"}}}';
      final msg = parseAppServerMessage(raw);
      expect(msg, isA<AppServerResponse>());
      final resp = msg as AppServerResponse;
      expect(resp.id, 1);
      expect(resp.result['thread']['id'], 'thr_abc');
      expect(resp.error, isNull);
    });

    test('parses error response', () {
      const raw =
          '{"id":2,"error":{"code":-32600,"message":"Invalid Request"}}';
      final msg = parseAppServerMessage(raw);
      expect(msg, isA<AppServerResponse>());
      final resp = msg as AppServerResponse;
      expect(resp.id, 2);
      expect(resp.error!['message'], 'Invalid Request');
    });

    test('notification with null id is still a notification', () {
      const raw = '{"method":"initialized","params":{}}';
      final msg = parseAppServerMessage(raw);
      expect(msg, isA<AppServerNotification>());
    });
  });

  group('ApprovalRequest', () {
    test('commandSummary returns joined command', () {
      const req = ApprovalRequest(
        requestId: 1,
        kind: 'commandExecution',
        threadId: 't',
        turnId: 'u',
        command: ['git', 'push', 'origin', 'main'],
      );
      expect(req.commandSummary, 'git push origin main');
    });

    test('commandSummary falls back when command is null', () {
      const req = ApprovalRequest(
        requestId: 2,
        kind: 'fileChange',
        threadId: 't',
        turnId: 'u',
      );
      expect(req.commandSummary, '(file change)');
    });
  });
}
