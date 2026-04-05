import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:xiao_pangxie_workbench/controllers/workbench_controller.dart';
import 'package:xiao_pangxie_workbench/models/runtime_config.dart';
import 'package:xiao_pangxie_workbench/services/app_server_service.dart';
import 'package:xiao_pangxie_workbench/ui/workbench_page.dart';

// Minimal fake service (no real WS needed for widget tests).
class _StubService extends AppServerService {
  @override
  bool get isConnected => false;
  @override
  Future<void> connect(String url) async {}
  @override
  Future<void> disconnect() async {}
}

void main() {
  testWidgets('WorkbenchPage renders connection panel and send button',
      (WidgetTester tester) async {
    final service = _StubService();
    final controller = WorkbenchController(service);
    const config = RuntimeConfig(
      provider: 'Codex',
      endpoint: 'ws://127.0.0.1:60000',
      authMethod: 'ChatGPT',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: WorkbenchPage(
          controller: controller,
          runtimeConfig: config,
          onOpenSettings: () {},
        ),
      ),
    );

    // Connection panel visible.
    expect(find.text('Connect'), findsOneWidget);

    // Send button visible.
    expect(find.text('Send'), findsOneWidget);

    // App title in AppBar.
    expect(find.textContaining('小螃蟹'), findsOneWidget);

    controller.dispose();
    service.dispose();
  });

  testWidgets('Send button is disabled when disconnected',
      (WidgetTester tester) async {
    final service = _StubService();
    final controller = WorkbenchController(service);
    const config = RuntimeConfig(
      provider: 'Codex',
      endpoint: 'ws://127.0.0.1:60000',
      authMethod: 'ChatGPT',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: WorkbenchPage(
          controller: controller,
          runtimeConfig: config,
          onOpenSettings: () {},
        ),
      ),
    );

    final sendBtn = tester.widget<ElevatedButton>(
      find.widgetWithText(ElevatedButton, 'Send'),
    );
    expect(sendBtn.onPressed, isNull);

    controller.dispose();
    service.dispose();
  });
}
