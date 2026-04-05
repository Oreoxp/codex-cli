import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xiao_pangxie_workbench/models/user_profile.dart';
import 'package:xiao_pangxie_workbench/models/runtime_config.dart';
import 'package:xiao_pangxie_workbench/services/settings_service.dart';
import 'package:xiao_pangxie_workbench/ui/setup_page.dart';

class _FakeSettingsService extends SettingsService {
  UserProfile? savedProfile;
  RuntimeConfig? savedConfig;

  @override
  Future<void> saveUserProfile(UserProfile profile) async {
    savedProfile = profile;
  }

  @override
  Future<void> saveRuntimeConfig(RuntimeConfig config) async {
    savedConfig = config;
  }
}

void main() {
  testWidgets('SetupPage saves profile and config', (tester) async {
    final service = _FakeSettingsService();

    await tester.pumpWidget(
      MaterialApp(
        home: SetupPage(settingsService: service),
      ),
    );

    await tester.enterText(find.byType(TextField).at(0), 'Test User');
    await tester.enterText(
      find.byType(TextField).at(1),
      'ws://localhost:9999',
    );

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(service.savedProfile?.name, 'Test User');
    expect(service.savedConfig?.endpoint, 'ws://localhost:9999');
    expect(service.savedConfig?.provider, 'Codex');
  });

  testWidgets('SetupPage validates empty name', (tester) async {
    final service = _FakeSettingsService();

    await tester.pumpWidget(
      MaterialApp(
        home: SetupPage(settingsService: service),
      ),
    );

    await tester.tap(find.text('Save'));
    await tester.pump();

    expect(find.text('Please enter your name'), findsOneWidget);
    expect(service.savedProfile, isNull);
  });
}
