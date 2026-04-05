import 'package:flutter/material.dart';

import 'controllers/workbench_controller.dart';
import 'models/runtime_config.dart';
import 'models/user_profile.dart';
import 'services/app_server_service.dart';
import 'services/settings_service.dart';
import 'ui/setup_page.dart';
import 'ui/workbench_page.dart';

void main() {
  runApp(const WorkbenchApp());
}

class WorkbenchApp extends StatefulWidget {
  const WorkbenchApp({super.key});

  @override
  State<WorkbenchApp> createState() => _WorkbenchAppState();
}

class _WorkbenchAppState extends State<WorkbenchApp> {
  late final AppServerService _service;
  late final SettingsService _settingsService;
  late final WorkbenchController _controller;

  UserProfile? _profile;
  RuntimeConfig? _runtimeConfig;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _service = AppServerService();
    _settingsService = SettingsService();
    _controller = WorkbenchController(_service);
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final profile = await _settingsService.loadUserProfile();
    final config = await _settingsService.loadRuntimeConfig();
    if (!mounted) return;
    setState(() {
      _profile = profile;
      _runtimeConfig = config;
      _controller.userProfile = profile;
      _controller.runtimeConfig = config;
      _loading = false;
    });

    // Auto-connect once we have a saved endpoint.
    if (config != null && !_controller.isConnected) {
      _controller.connect(config.endpoint);
    }
  }

  /// Open settings and reconnect if the config changed.
  Future<void> _openSettings(BuildContext context) async {
    final result = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => SetupPage(
          settingsService: _settingsService,
          existingProfile: _profile,
          existingConfig: _runtimeConfig,
        ),
      ),
    );
    if (result == true) {
      // Disconnect first so we can reconnect to possibly new endpoint.
      if (_controller.isConnected) {
        await _controller.disconnect();
      }
      await _loadSettings(); // reloads config and triggers auto-connect
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _service.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '小螃蟹 Workbench',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blue,
          brightness: Brightness.dark,
        ),
      ),
      home: _loading
          ? const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            )
          : _profile == null || _runtimeConfig == null
              ? SetupPage(
                  settingsService: _settingsService,
                  existingProfile: _profile,
                  existingConfig: _runtimeConfig,
                )
              : Builder(
                  builder: (context) => WorkbenchPage(
                    controller: _controller,
                    runtimeConfig: _runtimeConfig!,
                    onOpenSettings: () => _openSettings(context),
                  ),
                ),
    );
  }
}
