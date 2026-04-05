import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:xiao_pangxie_workbench/controllers/workbench_controller.dart';
import 'package:xiao_pangxie_workbench/models/runtime_config.dart';
import 'package:xiao_pangxie_workbench/services/app_server_service.dart';
import 'package:xiao_pangxie_workbench/ui/workbench_page.dart';

// Minimal stub — no real WS needed for widget tests.
class _StubService extends AppServerService {
  @override
  bool get isConnected => false;
  @override
  Future<void> connect(String url) async {}
  @override
  Future<void> disconnect() async {}
}

WorkbenchPage _page(WorkbenchController ctrl) => WorkbenchPage(
      controller: ctrl,
      runtimeConfig: const RuntimeConfig(
        provider: 'Codex',
        endpoint: 'ws://127.0.0.1:60000',
        authMethod: 'ChatGPT',
      ),
      onOpenSettings: () {},
    );

void main() {
  group('WorkbenchPage widget tests', () {
    testWidgets('renders app title and Send button', (tester) async {
      final service = _StubService();
      final ctrl = WorkbenchController(service);

      await tester.pumpWidget(MaterialApp(home: _page(ctrl)));

      expect(find.text('Send'), findsOneWidget);
      expect(find.textContaining('小螃蟹'), findsOneWidget);

      ctrl.dispose();
      service.dispose();
    });

    testWidgets('Send button is disabled when disconnected', (tester) async {
      final service = _StubService();
      final ctrl = WorkbenchController(service);

      await tester.pumpWidget(MaterialApp(home: _page(ctrl)));

      final btn = tester.widget<ElevatedButton>(
        find.widgetWithText(ElevatedButton, 'Send'),
      );
      expect(btn.onPressed, isNull);

      ctrl.dispose();
      service.dispose();
    });

    testWidgets('chat view shows empty state when no messages', (tester) async {
      final service = _StubService();
      final ctrl = WorkbenchController(service);

      await tester.pumpWidget(MaterialApp(home: _page(ctrl)));

      expect(find.textContaining('Send a prompt'), findsOneWidget);

      ctrl.dispose();
      service.dispose();
    });

    testWidgets('connection status bar shows Disconnected by default',
        (tester) async {
      final service = _StubService();
      final ctrl = WorkbenchController(service);

      await tester.pumpWidget(MaterialApp(home: _page(ctrl)));

      expect(find.text('Disconnected'), findsOneWidget);

      ctrl.dispose();
      service.dispose();
    });

    testWidgets('debug panel shows "Diff (none)" when no diff yet',
        (tester) async {
      final service = _StubService();
      final ctrl = WorkbenchController(service);

      await tester.pumpWidget(MaterialApp(home: _page(ctrl)));

      expect(find.textContaining('Diff'), findsOneWidget);

      ctrl.dispose();
      service.dispose();
    });
  });
}
