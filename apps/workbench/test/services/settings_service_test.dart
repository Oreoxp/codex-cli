import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xiao_pangxie_workbench/models/user_profile.dart';
import 'package:xiao_pangxie_workbench/models/runtime_config.dart';
import 'package:xiao_pangxie_workbench/services/settings_service.dart';

void main() {
  late SettingsService service;
  late Directory tempDir;

  setUp(() async {
    service = SettingsService();
    tempDir = await Directory.systemTemp.createTemp('xpx_test_');
    // Override HOME for testing
    Platform.environment['HOME'] = tempDir.path;
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  group('SettingsService', () {
    test('saveUserProfile and loadUserProfile', () async {
      const profile = UserProfile(name: 'Test User');
      await service.saveUserProfile(profile);

      final loaded = await service.loadUserProfile();
      expect(loaded, isNotNull);
      expect(loaded!.name, 'Test User');
    });

    test('saveRuntimeConfig and loadRuntimeConfig', () async {
      const config = RuntimeConfig(
        provider: 'Codex',
        endpoint: 'ws://localhost:9999',
        authMethod: 'API Key',
        apiKey: 'test-key',
      );
      await service.saveRuntimeConfig(config);

      final loaded = await service.loadRuntimeConfig();
      expect(loaded, isNotNull);
      expect(loaded!.provider, 'Codex');
      expect(loaded.endpoint, 'ws://localhost:9999');
      expect(loaded.authMethod, 'API Key');
      expect(loaded.apiKey, 'test-key');
    });

    test('returns null when no settings exist', () async {
      final profile = await service.loadUserProfile();
      final config = await service.loadRuntimeConfig();
      expect(profile, isNull);
      expect(config, isNull);
    });
  });
}
