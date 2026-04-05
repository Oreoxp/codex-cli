import 'dart:convert';
import 'dart:io';

import '../models/user_profile.dart';
import '../models/runtime_config.dart';

class SettingsService {
  Future<File> _getSettingsFile() async {
    final home = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '';
    final dir = Directory('$home/.xiao_pangxie');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return File('${dir.path}/settings.json');
  }

  Future<Map<String, dynamic>> _loadSettings() async {
    try {
      final file = await _getSettingsFile();
      if (!await file.exists()) return {};
      final content = await file.readAsString();
      return jsonDecode(content) as Map<String, dynamic>;
    } catch (_) {
      return {};
    }
  }

  Future<void> _saveSettings(Map<String, dynamic> settings) async {
    final file = await _getSettingsFile();
    await file.writeAsString(jsonEncode(settings));
  }

  Future<UserProfile?> loadUserProfile() async {
    final settings = await _loadSettings();
    final profileData = settings['userProfile'] as Map<String, dynamic>?;
    return profileData != null ? UserProfile.fromJson(profileData) : null;
  }

  Future<void> saveUserProfile(UserProfile profile) async {
    final settings = await _loadSettings();
    settings['userProfile'] = profile.toJson();
    await _saveSettings(settings);
  }

  Future<RuntimeConfig?> loadRuntimeConfig() async {
    final settings = await _loadSettings();
    final configData = settings['runtimeConfig'] as Map<String, dynamic>?;
    return configData != null ? RuntimeConfig.fromJson(configData) : null;
  }

  Future<void> saveRuntimeConfig(RuntimeConfig config) async {
    final settings = await _loadSettings();
    settings['runtimeConfig'] = config.toJson();
    await _saveSettings(settings);
  }
}
